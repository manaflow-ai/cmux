import Foundation

/// SSH keepalive values used by cmux-managed remote workspace connections.
///
/// The settings are intentionally represented as regular `-o` option strings
/// so an explicit SSH option from a URL, CLI invocation, or persisted workspace
/// remains authoritative over the configured defaults.
public struct SSHKeepaliveSettings: Codable, Equatable, Sendable {
    public static let defaultServerAliveInterval = 20
    public static let defaultServerAliveCountMax = 2
    public static let `default` = try! SSHKeepaliveSettings()

    public let sshServerAliveInterval: Int
    public let sshServerAliveCountMax: Int

    public init(
        sshServerAliveInterval: Int = Self.defaultServerAliveInterval,
        sshServerAliveCountMax: Int = Self.defaultServerAliveCountMax
    ) throws {
        guard Self.validInterval(sshServerAliveInterval) else {
            throw ValidationError.invalidInterval(sshServerAliveInterval)
        }
        guard Self.validCountMax(sshServerAliveCountMax) else {
            throw ValidationError.invalidCountMax(sshServerAliveCountMax)
        }
        self.sshServerAliveInterval = sshServerAliveInterval
        self.sshServerAliveCountMax = sshServerAliveCountMax
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sshServerAliveInterval: container.decodeIfPresent(Int.self, forKey: .sshServerAliveInterval)
                ?? Self.defaultServerAliveInterval,
            sshServerAliveCountMax: container.decodeIfPresent(Int.self, forKey: .sshServerAliveCountMax)
                ?? Self.defaultServerAliveCountMax
        )
    }

    /// Returns the configured keepalive options that are not already present in
    /// `existingOptions`. OpenSSH uses the first value it obtains, so preserving
    /// an existing key keeps explicit caller options ahead of cmux config.
    public func optionArguments(for existingOptions: [String]) -> [String] {
        var arguments: [String] = []
        if !Self.hasOptionKey(existingOptions, key: "ServerAliveInterval") {
            arguments += ["-o", "ServerAliveInterval=\(sshServerAliveInterval)"]
        }
        if !Self.hasOptionKey(existingOptions, key: "ServerAliveCountMax") {
            arguments += ["-o", "ServerAliveCountMax=\(sshServerAliveCountMax)"]
        }
        return arguments
    }

    /// Adds the configured options to an SSH option list when the caller has
    /// not already supplied the corresponding key.
    public func appendingMissingOptions(to existingOptions: [String]) -> [String] {
        var options = existingOptions
        if !Self.hasOptionKey(options, key: "ServerAliveInterval") {
            options.append("ServerAliveInterval=\(sshServerAliveInterval)")
        }
        if !Self.hasOptionKey(options, key: "ServerAliveCountMax") {
            options.append("ServerAliveCountMax=\(sshServerAliveCountMax)")
        }
        return options
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidInterval(Int)
        case invalidCountMax(Int)
    }

    private enum CodingKeys: String, CodingKey {
        case sshServerAliveInterval
        case sshServerAliveCountMax
    }

    private static func validInterval(_ value: Int) -> Bool {
        (1...3600).contains(value)
    }

    private static func validCountMax(_ value: Int) -> Bool {
        (1...100).contains(value)
    }

    private static func hasOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { option in
            option
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
                .first?
                .lowercased() == loweredKey
        }
    }
}
