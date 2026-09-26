public import Foundation

/// SSH keepalive values used by cmux-managed remote workspace connections.
///
/// Explicit SSH options take precedence. Keep these defaults separate from
/// durable workspace options so restored workspaces can use updated settings.
public struct SSHKeepaliveSettings: Codable, Equatable, Sendable {
    /// Default seconds between probes, preserving the existing SSH behavior.
    public static let defaultServerAliveInterval = 20
    /// Default number of unanswered probes tolerated.
    public static let defaultServerAliveCountMax = 2
    /// Built-in defaults for SSH remote workspaces.
    public static let `default` = SSHKeepaliveSettings(
        validatedInterval: defaultServerAliveInterval, validatedCountMax: defaultServerAliveCountMax
    )

    /// Seconds between probes, in the range 1 through 3600.
    public let sshServerAliveInterval: Int
    /// Unanswered probes tolerated, in the range 1 through 100.
    public let sshServerAliveCountMax: Int

    /// Creates validated keepalive defaults.
    ///
    /// - Parameters:
    ///   - sshServerAliveInterval: Seconds between probes; defaults to 20.
    ///   - sshServerAliveCountMax: Unanswered probes tolerated; defaults to 2.
    /// - Throws: ``ValidationError`` when either value is outside its supported range.
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

    private init(validatedInterval: Int, validatedCountMax: Int) {
        sshServerAliveInterval = validatedInterval
        sshServerAliveCountMax = validatedCountMax
    }

    /// Decodes a remote block, using built-in defaults for omitted keys.
    ///
    /// - Parameter decoder: Decoder positioned at the remote settings object.
    /// - Throws: A decoding or validation error for malformed settings.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sshServerAliveInterval: container.decodeIfPresent(Int.self, forKey: .sshServerAliveInterval)
                ?? Self.defaultServerAliveInterval,
            sshServerAliveCountMax: container.decodeIfPresent(Int.self, forKey: .sshServerAliveCountMax)
                ?? Self.defaultServerAliveCountMax
        )
    }

    /// Returns `-o` arguments for configured values missing from explicit options.
    ///
    /// OpenSSH uses the first value it obtains for each option key.
    /// - Parameter existingOptions: SSH option strings without the `-o` prefixes.
    /// - Returns: Alternating `-o` and option strings for missing keys.
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

    /// Appends configured values while preserving explicitly supplied option keys.
    ///
    /// - Parameter existingOptions: Explicit SSH option strings.
    /// - Returns: The effective SSH options for this connection.
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

    /// Decodes only the global remote block from a JSON configuration file.
    ///
    /// - Parameter data: JSON data after the caller has removed JSONC comments and trailing commas.
    /// - Returns: Remote defaults, or nil when the block is absent.
    /// - Throws: A parsing, decoding, or validation error for invalid input.
    public static func decodeConfiguration(_ data: Data) throws -> SSHKeepaliveSettings? {
        try JSONDecoder().decode(Configuration.self, from: data).remote
    }

    private struct Configuration: Decodable {
        let remote: SSHKeepaliveSettings?
    }

    /// An out-of-range keepalive setting.
    public enum ValidationError: Error, Equatable, Sendable {
        /// The interval is outside 1 through 3600 seconds.
        case invalidInterval(Int)
        /// The count is outside 1 through 100 probes.
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
