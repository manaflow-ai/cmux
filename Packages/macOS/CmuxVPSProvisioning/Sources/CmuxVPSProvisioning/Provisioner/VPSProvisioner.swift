internal import Foundation

/// Orchestrates VPS provisioning against one host: probe → plan → apply →
/// verify, plus status queries and teardown. All host mutation flows through
/// the plan computed by ``VPSProvisioningPlanner``, so `add` and `upgrade`
/// share one idempotent code path.
///
/// An actor so concurrent CLI invocations against the same instance
/// serialize; every dependency is injected (process runner, artifact
/// provider), keeping the orchestration testable with fakes.
public actor VPSProvisioner {
    private let host: VPSHostDescriptor
    private let ssh: VPSSSHClient
    private let artifacts: any VPSDaemonArtifactProviding

    /// Creates a provisioner.
    ///
    /// - Parameters:
    ///   - host: Host to provision.
    ///   - runner: Process runner seam (production: ``VPSProcessCommandRunner``).
    ///   - artifacts: Verified binary source (production: ``VPSManifestArtifactProvider``).
    public init(
        host: VPSHostDescriptor,
        runner: any VPSCommandRunning,
        artifacts: any VPSDaemonArtifactProviding
    ) {
        self.host = host
        self.ssh = VPSSSHClient(host: host, runner: runner)
        self.artifacts = artifacts
    }

    /// Provisions (or upgrades) the host, streaming progress events and
    /// ending with ``VPSProvisioningEvent/completed(_:)``.
    ///
    /// - Parameter force: Proceed even when applying the plan would destroy
    ///   live PTY sessions in the supervised daemon.
    public nonisolated func provisionEvents(force: Bool) -> AsyncThrowingStream<VPSProvisioningEvent, any Error> {
        makeEventStream { provisioner, yield in
            let outcome = try await provisioner.runProvision(force: force, yield: yield)
            yield(.completed(outcome))
        }
    }

    /// Tears down the supervised unit, streaming progress events and ending
    /// with ``VPSProvisioningEvent/removed(_:)``.
    ///
    /// - Parameters:
    ///   - keepSessions: Leave the daemon process running so on-host PTY
    ///     sessions survive; only the unit and VPS state directory go away.
    ///   - force: Stop the unit even when live PTY sessions would die.
    public nonisolated func removeEvents(keepSessions: Bool, force: Bool) -> AsyncThrowingStream<VPSProvisioningEvent, any Error> {
        makeEventStream { provisioner, yield in
            let outcome = try await provisioner.runRemove(keepSessions: keepSessions, force: force, yield: yield)
            yield(.removed(outcome))
        }
    }

    /// Queries host status from real daemon signals (probe + non-spawning
    /// daemon socket query); never mutates the host.
    public func status() async -> VPSHostStatus {
        let desiredVersion = artifacts.version
        let facts: VPSHostFacts
        do {
            facts = try await probeFacts()
        } catch {
            return VPSHostStatus(
                facts: nil,
                report: nil,
                health: VPSHostHealth.evaluate(facts: nil, report: nil, desiredVersion: desiredVersion),
                desiredVersion: desiredVersion
            )
        }
        let report = await queryDaemonReport(facts: facts)
        return VPSHostStatus(
            facts: facts,
            report: report,
            health: VPSHostHealth.evaluate(facts: facts, report: report, desiredVersion: desiredVersion),
            desiredVersion: desiredVersion
        )
    }

    // MARK: - Provision

    private func runProvision(
        force: Bool,
        yield: @Sendable @escaping (VPSProvisioningEvent) -> Void
    ) async throws -> VPSProvisionOutcome {
        yield(.probing(destination: host.destination))
        let facts = try await probeFacts()
        yield(.probed(
            goOS: facts.goOS ?? facts.unameOS,
            goArch: facts.goArch ?? facts.unameArch,
            distro: facts.distroPrettyName.isEmpty ? facts.distroID : facts.distroPrettyName
        ))

        let desiredVersion = artifacts.version
        let planner = VPSProvisioningPlanner(
            facts: facts,
            desiredVersion: desiredVersion,
            expectedBinarySHA256: artifacts.expectedSHA256(goOS: facts.goOS ?? "", goArch: facts.goArch ?? "")
        )
        let plan = try planner.makePlan()
        guard let layout = planner.layout else {
            throw VPSProvisioningError.unsupportedPlatform(unameOS: facts.unameOS, unameArch: facts.unameArch)
        }
        yield(.planned(plan))
        for note in plan.notes {
            yield(.note(note))
        }

        if plan.restartDisruptsActiveDaemon, !force {
            try await guardLiveSessions(facts: facts)
        }

        let scripts = VPSRemoteScripts(layout: layout)
        for step in plan.steps {
            yield(.applying(step))
            switch step {
            case .installBinary:
                yield(.acquiringArtifact(version: desiredVersion))
                try await installBinary(scripts: scripts, layout: layout, facts: facts)
            case .updateCurrentSymlink(let target):
                try await runStep(scripts.updateSymlinkScript(target: target), step: "update current symlink")
            case .writeUnitFile(let path, let scope):
                let unit = VPSSystemdUnit(layout: layout, scope: scope)
                try await runStep(
                    scripts.writeUnitFileScript(path: path, content: unit.fileContent()),
                    step: "write systemd unit"
                )
            case .daemonReload(let scope):
                try await runStep(scripts.daemonReloadScript(scope: scope), step: "systemd daemon-reload")
            case .enableLinger:
                // The script escalates (plain loginctl → passwordless sudo)
                // and reports the verified result; a refusal is surfaced as a
                // note here and as degraded health, not treated as fatal.
                let linger = try await ssh.runScript(scripts.enableLingerScript(), timeout: 30)
                if !linger.stdout.contains("\(VPSRemoteScripts.lingerResultMarker)yes") {
                    yield(.note(.lingerUnavailable))
                }
            case .enableUnit(let scope):
                try await runStep(scripts.enableUnitScript(scope: scope), step: "enable unit")
            case .restartUnit(let scope):
                try await runStep(scripts.restartUnitScript(scope: scope), step: "start unit")
            case .verifyHealth:
                break
            }
        }

        let health = try await verifyHealth(scripts: scripts, layout: layout, desiredVersion: desiredVersion)
        yield(.healthChecked(health))

        return VPSProvisionOutcome(
            installedVersion: desiredVersion,
            goOS: layout.goOS,
            goArch: layout.goArch,
            distroID: facts.distroID,
            unitScope: facts.hasSystemd ? facts.unitScope : nil,
            alreadyConverged: plan.isAlreadyConverged,
            health: health
        )
    }

    private func installBinary(
        scripts: VPSRemoteScripts,
        layout: VPSRemoteLayout,
        facts: VPSHostFacts
    ) async throws {
        let artifact = try await artifacts.materialize(goOS: layout.goOS, goArch: layout.goArch)
        try await runStep(scripts.makeBinaryDirectoryScript(), step: "create install directory")

        let tempPath = "\(layout.binaryPath).tmp-\(UUID().uuidString.prefix(8))"
        let uploadResult = try await ssh.upload(
            localPath: artifact.localURL.path,
            remotePath: tempPath,
            timeout: 180
        )
        guard uploadResult.status == 0 else {
            throw VPSProvisioningError.remoteCommandFailed(
                step: "upload daemon binary",
                detail: uploadResult.bestErrorLine ?? "scp exited \(uploadResult.status)"
            )
        }

        let finalize = try await ssh.runScript(
            scripts.finalizeBinaryScript(tempPath: tempPath, expectedSHA256: artifact.sha256),
            timeout: 60
        )
        if finalize.status == 65 {
            throw VPSProvisioningError.checksumMismatch(
                expected: artifact.sha256,
                actual: finalize.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard finalize.status == 0 else {
            throw VPSProvisioningError.remoteCommandFailed(
                step: "install daemon binary",
                detail: finalize.bestErrorLine ?? "ssh exited \(finalize.status)"
            )
        }
    }

    private func verifyHealth(
        scripts: VPSRemoteScripts,
        layout: VPSRemoteLayout,
        desiredVersion: String
    ) async throws -> VPSHostHealth {
        // End-to-end through the exact transport workspaces use: stdio proxy
        // → per-slot Unix socket auth → daemon hello.
        let hello = try await ssh.runScript(scripts.stdioHelloScript(binaryPath: layout.binaryPath), timeout: 30)
        guard hello.status == 0, helloResponseIsOK(stdout: hello.stdout) else {
            throw VPSProvisioningError.healthCheckFailed(
                detail: hello.bestErrorLine ?? "hello through the persistent daemon failed"
            )
        }

        // Re-probe so health reflects post-provision unit state, then read
        // the daemon's own signals (version, sessions, uptime).
        let refreshedFacts = try await probeFacts()
        let report = await queryDaemonReport(facts: refreshedFacts)
        return VPSHostHealth.evaluate(facts: refreshedFacts, report: report, desiredVersion: desiredVersion)
    }

    private func helloResponseIsOK(stdout: String) -> Bool {
        for line in stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return (object["ok"] as? Bool) == true
        }
        return false
    }

    // MARK: - Remove

    private func runRemove(
        keepSessions: Bool,
        force: Bool,
        yield: @Sendable @escaping (VPSProvisioningEvent) -> Void
    ) async throws -> VPSRemovalOutcome {
        yield(.probing(destination: host.destination))
        let facts = try await probeFacts()
        guard let goOS = facts.goOS, let goArch = facts.goArch else {
            throw VPSProvisioningError.unsupportedPlatform(unameOS: facts.unameOS, unameArch: facts.unameArch)
        }
        let layout = VPSRemoteLayout(
            homeDirectory: facts.homeDirectory,
            version: artifacts.version,
            goOS: goOS,
            goArch: goArch
        )
        let scripts = VPSRemoteScripts(layout: layout)

        var stoppedUnit = false
        var removedUnitFile = false
        if facts.hasSystemd, facts.unitFileExists {
            if !keepSessions {
                if !force {
                    try await guardLiveSessions(facts: facts)
                }
                try await runStep(scripts.stopUnitScript(scope: facts.unitScope), step: "stop unit")
                stoppedUnit = true
            }
            try await runStep(scripts.removeUnitScript(scope: facts.unitScope), step: "remove unit")
            removedUnitFile = true
        }
        try await runStep(scripts.removeVPSDirectoryScript(), step: "remove VPS state directory")
        return VPSRemovalOutcome(
            stoppedUnit: stoppedUnit,
            removedUnitFile: removedUnitFile,
            keptSessions: keepSessions || !stoppedUnit
        )
    }

    // MARK: - Shared helpers

    private func probeFacts() async throws -> VPSHostFacts {
        let probe = VPSHostProbeScript(version: artifacts.version)
        let result = try await ssh.runScript(probe.script(), timeout: 45)
        do {
            return try VPSHostFacts.parse(stdout: result.stdout)
        } catch {
            guard result.status == 0 else {
                throw VPSProvisioningError.sshFailed(
                    detail: result.bestErrorLine ?? "ssh exited \(result.status)"
                )
            }
            throw error
        }
    }

    /// Refuses destructive operations while the supervised daemon holds live
    /// PTY sessions. When the session count cannot be determined for an
    /// active unit, refuses conservatively (only `--force` proceeds).
    private func guardLiveSessions(facts: VPSHostFacts) async throws {
        guard facts.unitIsActive else { return }
        guard let report = await queryDaemonReport(facts: facts) else {
            throw VPSProvisioningError.healthCheckFailed(
                detail: "cannot determine live PTY session count for the active daemon; re-run with --force to proceed"
            )
        }
        let liveSessions = report.totalLiveSessions
        if liveSessions > 0 {
            throw VPSProvisioningError.liveSessionsPresent(count: liveSessions)
        }
    }

    private func queryDaemonReport(facts: VPSHostFacts) async -> VPSRemoteDaemonStatusReport? {
        guard let binaryPath = statusQueryBinaryPath(facts: facts) else { return nil }
        let layout = VPSRemoteLayout(
            homeDirectory: facts.homeDirectory,
            version: artifacts.version,
            goOS: facts.goOS ?? "",
            goArch: facts.goArch ?? ""
        )
        let scripts = VPSRemoteScripts(layout: layout)
        guard let result = try? await ssh.runScript(scripts.daemonStatusScript(binaryPath: binaryPath), timeout: 30),
              result.status == 0 else {
            return nil
        }
        return try? VPSRemoteDaemonStatusReport.parse(json: result.stdout)
    }

    private func statusQueryBinaryPath(facts: VPSHostFacts) -> String? {
        if !facts.currentSymlinkTarget.isEmpty {
            return facts.currentSymlinkTarget
        }
        guard let goOS = facts.goOS, let goArch = facts.goArch else { return nil }
        if facts.binaryExists {
            return VPSRemoteLayout(
                homeDirectory: facts.homeDirectory,
                version: artifacts.version,
                goOS: goOS,
                goArch: goArch
            ).binaryPath
        }
        guard let newest = facts.installedVersions.sorted().last else { return nil }
        return VPSRemoteLayout(
            homeDirectory: facts.homeDirectory,
            version: newest,
            goOS: goOS,
            goArch: goArch
        ).binaryPath
    }

    private nonisolated func makeEventStream(
        _ body: @Sendable @escaping (
            VPSProvisioner,
            @Sendable @escaping (VPSProvisioningEvent) -> Void
        ) async throws -> Void
    ) -> AsyncThrowingStream<VPSProvisioningEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(self) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runStep(_ script: String, step: String) async throws {
        let result = try await ssh.runScript(script, timeout: 60)
        guard result.status == 0 else {
            throw VPSProvisioningError.remoteCommandFailed(
                step: step,
                detail: result.bestErrorLine ?? "ssh exited \(result.status)"
            )
        }
    }
}
