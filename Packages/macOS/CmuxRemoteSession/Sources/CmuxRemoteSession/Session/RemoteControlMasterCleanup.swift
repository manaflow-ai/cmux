public import CmuxCore
internal import Foundation

/// Builds the reuse-only `ssh -O exit` request for a native SSH master.
public struct RemoteControlMasterCleanup: Sendable {
    /// Creates a cleanup argument builder.
    public init() {}

    /// Builds arguments that close the configured master without creating one.
    ///
    /// `ControlPath` and other transport options remain present so OpenSSH can
    /// find the existing socket. `ControlMaster` and `ControlPersist` are
    /// replaced by the leading reuse-only settings.
    ///
    /// - Parameter configuration: Native SSH workspace configuration.
    /// - Returns: Arguments for `/usr/bin/ssh`.
    public func cleanupArguments(configuration: WorkspaceRemoteConfiguration) -> [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]
        if let port = configuration.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identityFile.isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in normalizedCleanupOptions(configuration.sshOptions) {
            arguments += ["-o", option]
        }
        arguments += ["-O", "exit", configuration.destination]
        return arguments
    }

    private func normalizedCleanupOptions(_ options: [String]) -> [String] {
        let disallowedKeys: Set<String> = ["controlmaster", "controlpersist"]
        return options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed
                .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
                .first
                .map(String.init)?
                .lowercased()
            guard let key, !disallowedKeys.contains(key) else { return nil }
            return trimmed
        }
    }
}
