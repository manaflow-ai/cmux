import Foundation

/// A user-configured hook command and execution policy.
public struct CmuxHookDefinition: Codable, Sendable, Equatable {
    /// The default timeout for pre-spawn hooks, in milliseconds.
    public static let defaultPreSpawnTimeoutMs = 5_000

    /// The default timeout for event hooks, in milliseconds.
    public static let defaultEventTimeoutMs = 20_000

    /// The minimum accepted hook timeout, in milliseconds.
    public static let minimumTimeoutMs = 100

    /// The maximum accepted hook timeout, in milliseconds.
    public static let maximumTimeoutMs = 600_000

    /// The command path or command name to run.
    public let command: String

    /// Arguments passed to the command.
    public let args: [String]

    /// The hook timeout, clamped to `100...600000` milliseconds.
    public let timeoutMs: Int

    /// Whether this hook is enabled.
    public let enabled: Bool

    /// Creates a hook definition.
    /// - Parameters:
    ///   - command: The command path or command name to run; must not be blank.
    ///   - args: Arguments passed to the command.
    ///   - timeoutMs: Timeout in milliseconds; clamped to `100...600000`.
    ///   - enabled: Whether the hook is enabled.
    ///   - defaultTimeoutMs: Timeout used when `timeoutMs` is `nil`.
    public init(
        command: String,
        args: [String] = [],
        timeoutMs: Int? = nil,
        enabled: Bool = true,
        defaultTimeoutMs: Int = CmuxHookDefinition.defaultPreSpawnTimeoutMs
    ) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CmuxHookDefinitionDecodingError.blankCommand
        }
        self.command = trimmed
        self.args = args
        self.timeoutMs = Self.clampedTimeout(timeoutMs ?? defaultTimeoutMs)
        self.enabled = enabled
    }

    /// Creates a hook definition from JSON using the pre-spawn default timeout.
    /// - Parameter decoder: The decoder containing one hook object.
    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, defaultTimeoutMs: Self.defaultPreSpawnTimeoutMs)
    }

    /// Creates a hook definition from JSON with a caller-selected default timeout.
    /// - Parameters:
    ///   - decoder: The decoder containing one hook object.
    ///   - defaultTimeoutMs: Timeout used when the hook omits `timeoutMs`.
    public init(from decoder: any Decoder, defaultTimeoutMs: Int) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let command = try container.decode(String.self, forKey: .command)
        let args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        let timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        try self.init(
            command: command,
            args: args,
            timeoutMs: timeoutMs,
            enabled: enabled,
            defaultTimeoutMs: defaultTimeoutMs
        )
    }

    /// Encodes the hook definition.
    /// - Parameter encoder: The target encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encode(timeoutMs, forKey: .timeoutMs)
        try container.encode(enabled, forKey: .enabled)
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case args
        case timeoutMs
        case enabled
    }

    private static func clampedTimeout(_ value: Int) -> Int {
        min(max(value, minimumTimeoutMs), maximumTimeoutMs)
    }
}
