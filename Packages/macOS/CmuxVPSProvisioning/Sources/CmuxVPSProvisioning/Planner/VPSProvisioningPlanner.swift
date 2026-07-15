/// Pure decision core: computes the minimal idempotent plan that converges a
/// probed host on the desired daemon version and supervised unit.
///
/// The planner never performs I/O, so every decision (fresh install, repair,
/// upgrade, no-op, non-systemd report-only) is deterministic and unit-tested.
public struct VPSProvisioningPlanner: Equatable, Sendable {
    /// Probed host state.
    public var facts: VPSHostFacts
    /// Daemon version to converge on.
    public var desiredVersion: String
    /// SHA-256 of the verified local artifact, or `nil` when unknown (the
    /// dev-only explicit-binary override); with no expected digest an
    /// existing remote binary is trusted, matching the `cmux ssh` bootstrap.
    public var expectedBinarySHA256: String?

    /// Creates a planner.
    ///
    /// - Parameters:
    ///   - facts: Probed host state.
    ///   - desiredVersion: Daemon version to converge on.
    ///   - expectedBinarySHA256: Verified artifact digest, or `nil` when
    ///     unknown.
    public init(facts: VPSHostFacts, desiredVersion: String, expectedBinarySHA256: String?) {
        self.facts = facts
        self.desiredVersion = desiredVersion
        self.expectedBinarySHA256 = expectedBinarySHA256?.lowercased()
    }

    /// The layout implied by the probe, or `nil` when the platform is
    /// unsupported.
    public var layout: VPSRemoteLayout? {
        guard let goOS = facts.goOS, let goArch = facts.goArch else { return nil }
        return VPSRemoteLayout(
            homeDirectory: facts.homeDirectory,
            version: desiredVersion,
            goOS: goOS,
            goArch: goArch
        )
    }

    /// Computes the provisioning plan.
    ///
    /// - Returns: Steps that converge the host, with advisory notes.
    /// - Throws: ``VPSProvisioningError/unsupportedPlatform(unameOS:unameArch:)``
    ///   when the host has no published daemon build.
    public func makePlan() throws -> VPSProvisioningPlan {
        guard let layout else {
            throw VPSProvisioningError.unsupportedPlatform(
                unameOS: facts.unameOS,
                unameArch: facts.unameArch
            )
        }

        var steps: [VPSProvisioningStep] = []
        var notes: [VPSProvisioningPlan.Note] = []

        let needsBinaryInstall: Bool = {
            guard facts.binaryExists else { return true }
            guard let expectedBinarySHA256 else {
                // No expected digest (dev override): trust the existing
                // executable like the `cmux ssh` bootstrap does.
                return false
            }
            // Missing on-host digest is not verification — reinstall so the
            // upload path's mandatory checksum check settles it (and fails
            // loudly on hosts with no checksum tool).
            guard !facts.binarySHA256.isEmpty else { return true }
            return facts.binarySHA256 != expectedBinarySHA256
        }()
        if needsBinaryInstall {
            steps.append(.installBinary(version: desiredVersion, remotePath: layout.binaryPath))
        }

        if facts.currentSymlinkTarget != layout.binaryPath {
            steps.append(.updateCurrentSymlink(target: layout.binaryPath))
        }

        guard facts.hasSystemd else {
            notes.append(.systemdUnavailable)
            steps.append(.verifyHealth)
            return VPSProvisioningPlan(steps: steps, notes: notes)
        }

        let scope = facts.unitScope
        let desiredUnit = VPSSystemdUnit(layout: layout, scope: scope)
        let unitContentChanged = !facts.unitFileExists
            || facts.unitFileSHA256 != desiredUnit.contentSHA256()
        if unitContentChanged {
            steps.append(.writeUnitFile(path: layout.unitFilePath(scope: scope), scope: scope))
            steps.append(.daemonReload(scope: scope))
        }

        if scope == .user, !facts.lingerEnabled {
            steps.append(.enableLinger)
            notes.append(.lingerBestEffort)
        }

        if facts.unitEnabledState != "enabled" {
            steps.append(.enableUnit(scope: scope))
        }

        // Restart when the daemon is not running, or when what it should be
        // running changed (binary, symlink target, or unit definition). A
        // healthy converged daemon is left untouched.
        let executionChanged = needsBinaryInstall
            || facts.currentSymlinkTarget != layout.binaryPath
            || unitContentChanged
        let needsRestart = !facts.unitIsActive || executionChanged
        if needsRestart {
            steps.append(.restartUnit(scope: scope))
        }

        steps.append(.verifyHealth)
        return VPSProvisioningPlan(
            steps: steps,
            notes: notes,
            restartDisruptsActiveDaemon: needsRestart && facts.unitIsActive
        )
    }
}
