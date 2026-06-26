import Foundation

/// A single right-sidebar Dock control parsed from the Dock config file.
///
/// Pure configuration value: identity (`id`), display `title`, the shell
/// `command` to run, an optional `cwd`, an optional pane `height`, and `env`
/// overrides. Decoding trims whitespace, defaults a blank title to `id`, and
/// rejects a blank `id` or `command` (throwing with the app-injected
/// ``DockControlDecodingStrings``). Encoding omits an empty `env`.
public struct DockControlDefinition: Codable, Equatable, Identifiable {
    /// Stable identity for the control; never blank after decoding.
    public let id: String
    /// Display title; defaults to ``id`` when blank.
    public let title: String
    /// Shell command the control's terminal runs; never blank after decoding.
    public let command: String
    /// Optional working directory; trimmed, resolved against a base directory.
    public let cwd: String?
    /// Optional pane height in points.
    public let height: Double?
    /// Environment overrides applied to the control's terminal.
    public let env: [String: String]

    /// Creates a Dock control definition with the given configuration.
    public init(
        id: String,
        title: String,
        command: String,
        cwd: String? = nil,
        height: Double? = nil,
        env: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.cwd = cwd
        self.height = height
        self.env = env
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case command
        case cwd
        case height
        case env
    }

    /// Decodes a control, trimming whitespace, defaulting a blank title to the
    /// id, and rejecting a blank id or command with the app-injected
    /// ``DockControlDecodingStrings`` (English defaults when none are injected).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? rawID
        let rawCommand = try container.decode(String.self, forKey: .command)
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let strings = decoder.userInfo[.dockControlDecodingStrings] as? DockControlDecodingStrings
        guard !normalizedID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: strings?.blankControlID ?? "Dock control id must not be blank."
            )
        }
        guard !normalizedCommand.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .command,
                in: container,
                debugDescription: strings?.blankControlCommand ?? "Dock control command must not be blank."
            )
        }
        id = normalizedID
        title = normalizedTitle.isEmpty ? normalizedID : normalizedTitle
        command = normalizedCommand
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }

    /// Encodes the control, omitting an empty `env`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(height, forKey: .height)
        if !env.isEmpty {
            try container.encode(env, forKey: .env)
        }
    }
}
