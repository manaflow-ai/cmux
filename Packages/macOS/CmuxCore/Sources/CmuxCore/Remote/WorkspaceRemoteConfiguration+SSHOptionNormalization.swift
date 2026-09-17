import Foundation
internal import CmuxFoundation

// Pure SSH-option normalization vocabulary for remote configurations.
//
// These are static members (not instance members) because they normalize raw
// inputs before a configuration value exists, and they are scoped on
// `WorkspaceRemoteConfiguration` because that is the domain type that owns the
// SSH-option vocabulary (formerly the file-private `WorkspaceRemoteSSHOptionFilter`
// namespace in the app target).
extension WorkspaceRemoteConfiguration {
    private static let transientControlSocketKeys: Set<String> = [
        "controlmaster",
        "controlpath",
        "controlpersist",
    ]

    /// Options that survive snapshot/restore: trimmed, with transient
    /// control-socket options (`ControlMaster`/`ControlPath`/`ControlPersist`) dropped.
    public static func durableSSHOptions(_ options: [String]) -> [String] {
        filteredSSHOptions(options, droppingKeys: transientControlSocketKeys)
    }

    /// Options propagated to a forked workspace (same as the durable subset).
    public static func forkedWorkspaceSSHOptions(_ options: [String]) -> [String] {
        durableSSHOptions(options)
    }

    /// Options trimmed of whitespace and empties, with nothing dropped.
    public static func trimmedSSHOptions(_ options: [String]) -> [String] {
        filteredSSHOptions(options, droppingKeys: [])
    }

    private static func filteredSSHOptions(_ options: [String], droppingKeys keys: Set<String>) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.filter { option in
            guard let key = SSHAgentSocketResolver().optionKey(option) else { return true }
            return !keys.contains(key)
        }
    }

    /// Trims `value`; returns `nil` for `nil` or whitespace-only input.
    public static func normalizedOptionalValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Validates a persistent daemon slot name (1-128 chars of `[A-Za-z0-9._-]`,
    /// not `.` or `..`); returns `nil` for anything else.
    public static func normalizedPersistentDaemonSlot(_ value: String?) -> String? {
        guard let slot = normalizedOptionalValue(value),
              slot != ".",
              slot != "..",
              slot.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return slot
    }

    /// Trims an identity file path and expands a leading `~`.
    public static func normalizedIdentityPath(_ value: String?) -> String? {
        guard let trimmed = normalizedOptionalValue(value) else { return nil }
        guard trimmed.hasPrefix("~") else { return trimmed }
        return normalizedOptionalValue((trimmed as NSString).expandingTildeInPath) ?? trimmed
    }

    /// Normalizes an SSH agent socket path and expands `~` so environment injection receives a usable path.
    static func normalizedAgentSocketPath(_ value: String?) -> String? {
        SSHAgentSocketResolver().normalizedAgentSocketPath(value)
    }

    /// Returns a normalized agent socket path only when it currently exists.
    static func existingAgentSocketPath(_ value: String?) -> String? {
        guard let path = normalizedAgentSocketPath(value),
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    /// True when `options` contains an option whose key matches `key`
    /// (case-insensitive, `=` or whitespace separated).
    public static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        SSHAgentSocketResolver().hasOptionKey(options, key: key)
    }

    /// Resolves a durable `ForwardAgent` SSH option into the current local agent socket path, when one is usable.
    static func sshAgentSocketPath(for options: [String]) -> String? {
        SSHAgentSocketResolver().agentSocketPath(for: options)
    }
}
