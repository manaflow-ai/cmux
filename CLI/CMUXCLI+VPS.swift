import CmuxCore
import CmuxVPSProvisioning
import Foundation

/// One-shot hand-off box for `runVPSBlocking`: written once by the worker
/// task before it signals the semaphore, read once after the wait — the
/// semaphore orders the hand-off, hence `@unchecked Sendable`.
private final class VPSBlockingResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

// cmux vps: one-command BYO VPS onboarding (issue #8003 Phase 2).
//
// Standalone like `remote-daemon-status` — provisioning runs entirely in the
// CLI over the user's own SSH transport, so onboarding works before the app
// socket exists. State lives in the shared VPS host registry; `cmux ssh`
// reads it to pin workspaces on registered hosts to the supervised daemon
// slot.
extension CMUXCLI {
    func runVPSCommand(commandArgs: [String], jsonOutput: Bool) throws {
        guard let subcommand = commandArgs.first, subcommand != "help", subcommand != "--help", subcommand != "-h" else {
            print(Self.vpsUsageText())
            return
        }
        let subArgs = Array(commandArgs.dropFirst())
        switch subcommand {
        case "add":
            try runVPSProvision(commandArgs: subArgs, jsonOutput: jsonOutput, requireRegistered: false)
        case "upgrade":
            try runVPSProvision(commandArgs: subArgs, jsonOutput: jsonOutput, requireRegistered: true)
        case "list":
            try runVPSList(jsonOutput: jsonOutput)
        case "status":
            try runVPSStatus(commandArgs: subArgs, jsonOutput: jsonOutput)
        case "remove":
            try runVPSRemove(commandArgs: subArgs, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: String(
                localized: "cli.vps.unknownSubcommand",
                defaultValue: "unknown vps subcommand; expected add, list, status, upgrade, or remove"
            ))
        }
    }

    static func vpsUsageText() -> String {
        """
        cmux vps - provision a personal VPS as a direct cmux backend

        Usage:
          cmux vps add <user@host> [--port N] [--identity FILE] [--ssh-option OPT]... [--name NAME] [--force]
          cmux vps list
          cmux vps status [<user@host>]
          cmux vps upgrade <user@host> [--force]
          cmux vps remove <user@host> [--keep-sessions] [--force]

        add installs the checksum-verified cmuxd-remote daemon over your existing
        SSH auth, supervises it with a systemd unit, and verifies health end to
        end. Re-running add (or upgrade) converges the host idempotently and
        refuses to restart a daemon with live PTY sessions unless --force.
        remove stops and deletes the unit; --keep-sessions leaves the daemon
        (and its PTY sessions) running. All terminal, agent, and browser traffic
        for VPS workspaces flows directly between this Mac and the host.
        """
    }

    // MARK: - Shared plumbing

    private struct VPSCLIContext {
        let registry: VPSHostRegistry
        let artifacts: VPSManifestArtifactProvider
    }

    private func makeVPSContext() -> VPSCLIContext {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var manifest: WorkspaceRemoteDaemonManifest?
        if let embedded = WorkspaceRemoteDaemonManifest(infoDictionary: Bundle.main.infoDictionary) {
            manifest = embedded
        } else {
            for plistURL in candidateInfoPlistURLs() {
                guard let raw = NSDictionary(contentsOf: plistURL) as? [String: Any],
                      let embedded = WorkspaceRemoteDaemonManifest(infoDictionary: raw) else {
                    continue
                }
                manifest = embedded
                break
            }
        }
        let fallbackVersion = resolvedVersionInfo()["CFBundleShortVersionString"] ?? "dev"
        return VPSCLIContext(
            registry: VPSHostRegistry(homeDirectory: home),
            artifacts: VPSManifestArtifactProvider(
                manifest: manifest,
                homeDirectory: home,
                fallbackVersion: fallbackVersion
            )
        )
    }

    /// Bridges the CLI's synchronous command loop onto async provisioning
    /// work (same pattern as the window-namespace `runBlocking` helper).
    private func runVPSBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = VPSBlockingResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let value = try await work()
                box.result = .success(value)
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else {
            throw CLIError(message: "vps command produced no result")
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error as VPSProvisioningError):
            throw CLIError(message: error.detailDescription)
        case .failure(let error):
            throw error
        }
    }

    private func vpsHostDescriptor(
        commandArgs: [String],
        registryEntry: VPSRegisteredHost?
    ) throws -> (VPSHostDescriptor, remaining: [String]) {
        let (portRaw, rest0) = parseOption(commandArgs, name: "--port")
        let (identity, rest1) = parseOption(rest0, name: "--identity")
        var sshOptions: [String] = []
        var rest2 = rest1
        while let (value, next) = extractRepeatedOption(rest2, name: "--ssh-option") {
            sshOptions.append(value)
            rest2 = next
        }
        let positionals = rest2.filter { !$0.hasPrefix("-") }
        let destination = positionals.first ?? registryEntry?.host.destination
        guard let destination, !destination.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.vps.missingDestination",
                defaultValue: "vps requires a destination like user@host"
            ))
        }
        var port: Int?
        if let portRaw {
            guard let parsed = Int(portRaw), (1...65535).contains(parsed) else {
                throw CLIError(message: String(
                    localized: "cli.vps.invalidPort",
                    defaultValue: "invalid --port value"
                ))
            }
            port = parsed
        } else {
            port = registryEntry?.host.port
        }
        let descriptor = VPSHostDescriptor(
            destination: destination,
            port: port,
            identityFile: identity ?? registryEntry?.host.identityFile,
            sshOptions: sshOptions.isEmpty ? (registryEntry?.host.sshOptions ?? []) : sshOptions
        )
        let remaining = rest2.filter { $0 != destination }
        return (descriptor, remaining)
    }

    private func extractRepeatedOption(_ args: [String], name: String) -> (String, [String])? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        var remaining = args
        let value = remaining[index + 1]
        remaining.removeSubrange(index...(index + 1))
        return (value, remaining)
    }

    // MARK: - add / upgrade

    private func runVPSProvision(commandArgs: [String], jsonOutput: Bool, requireRegistered: Bool) throws {
        let context = makeVPSContext()
        let force = hasFlag(commandArgs, name: "--force")
        let (nameArg, argsWithoutName) = parseOption(commandArgs, name: "--name")
        let filteredArgs = argsWithoutName.filter { $0 != "--force" }

        let probeDescriptor = try vpsHostDescriptor(commandArgs: filteredArgs, registryEntry: nil).0
        let existingEntry = try runVPSBlocking { [registry = context.registry] in
            try await registry.entry(for: probeDescriptor)
        }
        if requireRegistered, existingEntry == nil {
            throw CLIError(message: VPSProvisioningError.hostNotRegistered(
                destination: probeDescriptor.destination
            ).detailDescription)
        }
        let (descriptor, _) = try vpsHostDescriptor(commandArgs: filteredArgs, registryEntry: existingEntry)

        let provisioner = VPSProvisioner(
            host: descriptor,
            runner: VPSProcessCommandRunner(),
            artifacts: context.artifacts
        )
        let quiet = jsonOutput
        let outcome: VPSProvisionOutcome = try runVPSBlocking {
            var finished: VPSProvisionOutcome?
            for try await event in provisioner.provisionEvents(force: force) {
                if case .completed(let value) = event {
                    finished = value
                }
                if !quiet {
                    Self.printVPSEvent(event)
                }
            }
            guard let finished else {
                throw VPSProvisioningError.healthCheckFailed(detail: "provisioning ended without a result")
            }
            return finished
        }

        let now = Int(Date().timeIntervalSince1970)
        let entry = VPSRegisteredHost(
            host: descriptor,
            name: nameArg ?? existingEntry?.name,
            slot: existingEntry?.slot ?? VPSRemoteLayout.sharedSlot,
            unitScope: outcome.unitScope,
            installedVersion: outcome.installedVersion,
            goOS: outcome.goOS,
            goArch: outcome.goArch,
            distroID: outcome.distroID,
            addedAtUnix: existingEntry?.addedAtUnix ?? now,
            lastSeenAtUnix: now
        )
        try runVPSBlocking { [registry = context.registry] in
            try await registry.upsert(entry)
        }

        if jsonOutput {
            print(jsonString(Self.vpsOutcomePayload(outcome: outcome, entry: entry)))
            return
        }
        if outcome.alreadyConverged {
            print(String(
                localized: "cli.vps.alreadyConverged",
                defaultValue: "Host already up to date."
            ))
        }
        print(String(
            localized: "cli.vps.addSuccess",
            defaultValue: "VPS ready. Open a workspace with: cmux ssh \(descriptor.destination)"
        ))
    }

    // MARK: - list

    private func runVPSList(jsonOutput: Bool) throws {
        let context = makeVPSContext()
        let hosts = try runVPSBlocking { [registry = context.registry] in
            try await registry.allHosts()
        }
        if jsonOutput {
            print(jsonString(["hosts": hosts.map(Self.vpsEntryPayload)]))
            return
        }
        if hosts.isEmpty {
            print(String(
                localized: "cli.vps.listEmpty",
                defaultValue: "No VPS hosts registered. Add one with: cmux vps add user@host"
            ))
            return
        }
        for entry in hosts {
            let name = entry.name.map { " (\($0))" } ?? ""
            let scope = entry.unitScope.map(\.rawValue) ?? "none"
            print("\(entry.host.registryKey)\(name)  \(entry.goOS)/\(entry.goArch)  v\(entry.installedVersion)  unit:\(scope)")
        }
    }

    // MARK: - status

    private func runVPSStatus(commandArgs: [String], jsonOutput: Bool) throws {
        let context = makeVPSContext()
        let hasPositional = commandArgs.contains { !$0.hasPrefix("-") }
        let allHosts = try runVPSBlocking { [registry = context.registry] in
            try await registry.allHosts()
        }
        let targets: [VPSRegisteredHost]
        if hasPositional {
            let descriptor = try vpsHostDescriptor(commandArgs: commandArgs, registryEntry: nil).0
            if let entry = allHosts.first(where: { $0.host.registryKey == descriptor.registryKey }) {
                targets = [entry]
            } else {
                targets = [VPSRegisteredHost(
                    host: descriptor,
                    installedVersion: "unknown",
                    goOS: "",
                    goArch: "",
                    addedAtUnix: 0
                )]
            }
        } else {
            targets = allHosts
            if targets.isEmpty {
                if jsonOutput {
                    print(jsonString(["hosts": [Any]()]))
                } else {
                    print(String(
                        localized: "cli.vps.listEmpty",
                        defaultValue: "No VPS hosts registered. Add one with: cmux vps add user@host"
                    ))
                }
                return
            }
        }

        var payloads: [[String: Any]] = []
        for entry in targets {
            let provisioner = VPSProvisioner(
                host: entry.host,
                runner: VPSProcessCommandRunner(),
                artifacts: context.artifacts
            )
            let status = try runVPSBlocking { await provisioner.status() }
            if jsonOutput {
                payloads.append(Self.vpsStatusPayload(entry: entry, status: status))
            } else {
                Self.printVPSStatusLine(entry: entry, status: status)
            }
        }
        if jsonOutput {
            print(jsonString(["hosts": payloads]))
        }
    }

    // MARK: - remove

    private func runVPSRemove(commandArgs: [String], jsonOutput: Bool) throws {
        let context = makeVPSContext()
        let keepSessions = hasFlag(commandArgs, name: "--keep-sessions")
        let force = hasFlag(commandArgs, name: "--force")
        let filteredArgs = commandArgs.filter { $0 != "--keep-sessions" && $0 != "--force" }

        let probeDescriptor = try vpsHostDescriptor(commandArgs: filteredArgs, registryEntry: nil).0
        let existingEntry = try runVPSBlocking { [registry = context.registry] in
            try await registry.entry(for: probeDescriptor)
        }
        let (descriptor, _) = try vpsHostDescriptor(commandArgs: filteredArgs, registryEntry: existingEntry)

        let provisioner = VPSProvisioner(
            host: descriptor,
            runner: VPSProcessCommandRunner(),
            artifacts: context.artifacts
        )
        let quiet = jsonOutput
        let outcome: VPSRemovalOutcome = try runVPSBlocking {
            var finished: VPSRemovalOutcome?
            for try await event in provisioner.removeEvents(keepSessions: keepSessions, force: force) {
                if case .removed(let value) = event {
                    finished = value
                }
                if !quiet {
                    Self.printVPSEvent(event)
                }
            }
            guard let finished else {
                throw VPSProvisioningError.healthCheckFailed(detail: "removal ended without a result")
            }
            return finished
        }
        try runVPSBlocking { [registry = context.registry] in
            _ = try await registry.remove(descriptor)
        }

        if jsonOutput {
            print(jsonString([
                "removed": true,
                "stopped_unit": outcome.stoppedUnit,
                "removed_unit_file": outcome.removedUnitFile,
                "kept_sessions": outcome.keptSessions,
            ]))
            return
        }
        if outcome.keptSessions {
            print(String(
                localized: "cli.vps.removedKeptSessions",
                defaultValue: "VPS removed from cmux. The daemon and its PTY sessions were left running on the host."
            ))
        } else {
            print(String(
                localized: "cli.vps.removed",
                defaultValue: "VPS removed. The supervised daemon was stopped."
            ))
        }
    }

    // Rendering and `--json` payload builders live in CMUXCLI+VPSOutput.swift.
    // MARK: - cmux ssh slot pinning

    /// The supervised daemon slot for a registered VPS destination, or `nil`
    /// when the host is not registered (plain `cmux ssh` keeps its
    /// per-workspace slot). Errors read as "not registered" — pinning is an
    /// optimization, never a gate.
    static func vpsRegisteredSlot(destination: String, port: Int?) -> String? {
        let registry = VPSHostRegistry(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        final class SlotBox: @unchecked Sendable {
            // Written once before the semaphore signal, read after the wait.
            var slot: String?
        }
        let box = SlotBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.slot = try? await registry.entry(destination: destination, port: port)?.slot
            semaphore.signal()
        }
        semaphore.wait()
        return box.slot
    }
}
