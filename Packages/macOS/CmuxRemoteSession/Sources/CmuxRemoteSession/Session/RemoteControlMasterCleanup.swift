public import CmuxCore

/// Builds the `ssh -O exit` argv that tears down a lingering SSH ControlMaster
/// multiplexing socket for a remote workspace whose last terminal session has
/// ended (or whose surface was closed/transferred).
///
/// This is the pure, frozen-wire half of the legacy
/// `Workspace.requestSSHControlMasterCleanupIfNeeded(configuration:)`: given a
/// ``WorkspaceRemoteConfiguration`` it produces the exact argument vector the
/// app spawns against `/usr/bin/ssh`. The app-side witness still owns the
/// spawn (its serial cleanup queue, the `Process` lifecycle, and the XCTest
/// override), because that cleanup runs after the session coordinator is gone
/// and is pinned by the process-wide test seam; only the argv computation
/// belongs in the package, where it sits beside the other SSH-argument
/// builders and can be unit-tested without an app target.
///
/// The argv is protocol-frozen: option order (`BatchMode=yes`,
/// `ControlMaster=no`, then `-p`/`-i`, then the caller's surviving
/// `-o` options, then `-O exit <destination>`), the `controlmaster` /
/// `controlpersist` option stripping (so the cleanup connection never tries to
/// open or persist its own master), and the case-insensitive option-key parsing
/// are byte-faithful to the legacy static helpers and covered by
/// `WorkspaceRemoteConnectionTests`.
///
/// A value type (no stored state) rather than a static namespace: it is
/// constructed at the call site and its members are instance methods, per the
/// no-static-namespace convention.
public struct RemoteControlMasterCleanup: Sendable {
    /// Creates a cleanup argv builder.
    public init() {}

    /// The `ssh` argument vector that closes the ControlMaster for
    /// `configuration`, or `nil` when no cleanup argv applies.
    ///
    /// Always returns a non-`nil` argv for a valid configuration; the
    /// `Optional` return preserves the legacy signature so the app-side spawn
    /// shim can early-out symmetrically.
    public func cleanupArguments(configuration: WorkspaceRemoteConfiguration) -> [String]? {
        let sshOptions = normalizedCleanupOptions(configuration.sshOptions)
        var arguments: [String] = [
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
        for option in sshOptions {
            arguments += ["-o", option]
        }
        arguments += ["-O", "exit", configuration.destination]
        return arguments
    }

    /// Drops `ControlMaster`/`ControlPersist` options (and blank entries) from
    /// the configuration's SSH options so the cleanup connection neither opens
    /// nor persists its own multiplexing master.
    func normalizedCleanupOptions(_ options: [String]) -> [String] {
        let disallowedKeys: Set<String> = ["controlmaster", "controlpersist"]
        return options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let key = optionKey(trimmed) else { return nil }
            return disallowedKeys.contains(key) ? nil : trimmed
        }
    }

    /// The lowercased option key of an `ssh -o` entry (the token before the
    /// first `=` or whitespace), or `nil` for a blank entry.
    func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }
}
