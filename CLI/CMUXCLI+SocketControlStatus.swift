import Darwin
import Foundation
import CmuxSettings

extension CMUXCLI {
    /// Reports the effective socket policy without connecting to the socket.
    /// This remains usable when the listener is forced off and deliberately
    /// labels live enforcement as unobserved rather than treating a separate
    /// defaults reader as proof that a running server applied the value.
    func runSocketControlStatusCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        environment: [String: String]
    ) throws {
        let remaining = commandArgs.filter { $0 != "--json" }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux socket-status [--json]")
        }

        let domain = socketControlStatusDomain(environment: environment)
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        let resolution = SocketControlPolicyResolver(
            defaults: defaults,
            environment: environment,
            bundleIdentifier: domain
        ).resolve()
        let socketPath = SocketControlSettings.socketPath(
            environment: environment,
            bundleIdentifier: domain,
            isDebugBuild: false
        )
        let socketPathState = socketControlSocketPathState(socketPath)
        let payload: [String: Any] = [
            "effective_mode": resolution.mode.rawValue,
            "configured_mode": resolution.configuredMode.rawValue,
            "managed": resolution.isManaged,
            "managed_source": resolution.managedSource ?? NSNull(),
            "policy_key": ManagedDevicePolicyKey.socketControlMode.rawValue,
            "forced_value_status": resolution.forcedValueStatus ?? "unmanaged",
            "socket_path": socketPath,
            "socket_path_state": socketPathState,
            "live_enforcement": "not_observed",
            "observation_scope": "profile_and_socket_path",
        ]

        if jsonOutput || commandArgs.contains("--json") {
            print(jsonString(payload))
            return
        }

        let source = resolution.managedSource.map { " (\($0))" } ?? ""
        let format = String(
            localized: "cli.socketControlStatus.summary",
            defaultValue: "Socket control mode: %@%@. Live enforcement: not observed."
        )
        print(String.localizedStringWithFormat(format, resolution.mode.rawValue, source))
        print(String(
            localized: "cli.socketControlStatus.detail",
            defaultValue: "Use --json for the profile source and socket-path observation. This command never connects to the automation socket."
        ))
    }

    private func socketControlStatusDomain(environment: [String: String]) -> String {
        let candidates = [
            environment["CMUX_BUNDLE_ID"],
            CLIExecutableLocator.enclosingAppBundle()?.bundleIdentifier,
            ManagedDevicePolicy.releasePayloadDomain,
        ]
        return candidates
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? ManagedDevicePolicy.releasePayloadDomain
    }

    private func socketControlSocketPathState(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "absent" }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) ? "present" : "other"
    }
}
