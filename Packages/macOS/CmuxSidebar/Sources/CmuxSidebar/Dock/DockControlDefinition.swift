import Foundation

/// A single Dock control loaded from `dock.json`.
///
/// Back-compat: existing terminal-only configs omit `type`/`url` and require
/// `command`; those decode unchanged as `.terminal` entries. New configs may add
/// `"type": "browser"` with a `url` to seed a browser pane.
///
/// Decoding trims whitespace, defaults a blank title to `id`, and validates per
/// kind (terminal requires `command`, browser requires `url`), throwing with the
/// app-injected ``DockControlDecodingStrings`` (English defaults when none are
/// injected). Encoding keeps terminal entries in the legacy schema (no `type`
/// key) and omits an empty `env`.
public struct DockControlDefinition: Codable, Equatable, Identifiable, Sendable {
    /// Stable identity for the control; never blank after decoding.
    public let id: String
    /// Display title; defaults to ``id`` when blank.
    public let title: String
    /// The kind of surface this control hosts (terminal or browser).
    public let kind: DockSurfaceKind
    /// Shell command a terminal control runs; non-nil after decoding a terminal.
    public let command: String?
    /// URL a browser control seeds; non-nil after decoding a browser.
    public let url: String?
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
        kind: DockSurfaceKind = .terminal,
        command: String? = nil,
        url: String? = nil,
        cwd: String? = nil,
        height: Double? = nil,
        env: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.command = command
        self.url = url
        self.cwd = cwd
        self.height = height
        self.env = env
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case command
        case url
        case cwd
        case height
        case env
    }

    /// Decodes a control, trimming whitespace, defaulting a blank title to the
    /// id, and validating per kind with the app-injected
    /// ``DockControlDecodingStrings`` (English defaults when none are injected).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let strings = decoder.userInfo[.dockControlDecodingStrings] as? DockControlDecodingStrings

        let rawID = try container.decode(String.self, forKey: .id)
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: strings?.blankControlID ?? "Dock control id must not be blank."
            )
        }

        let resolvedKind: DockSurfaceKind
        if let rawType = try container.decodeIfPresent(String.self, forKey: .type)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawType.isEmpty {
            guard let parsed = DockSurfaceKind(rawValue: rawType) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: strings?.unknownControlType ?? "Dock control type must be terminal or browser."
                )
            }
            resolvedKind = parsed
        } else {
            resolvedKind = .terminal
        }

        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? rawID
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedCommand = try container.decodeIfPresent(String.self, forKey: .command)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = try container.decodeIfPresent(String.self, forKey: .url)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch resolvedKind {
        case .terminal:
            guard let normalizedCommand, !normalizedCommand.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .command,
                    in: container,
                    debugDescription: strings?.blankControlCommand ?? "Dock control command must not be blank."
                )
            }
            command = normalizedCommand
            url = nil
        case .browser:
            guard let normalizedURL, !normalizedURL.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url,
                    in: container,
                    debugDescription: strings?.blankControlURL ?? "Dock browser control url must not be blank."
                )
            }
            url = normalizedURL
            command = nil
        }

        id = normalizedID
        title = normalizedTitle.isEmpty ? normalizedID : normalizedTitle
        kind = resolvedKind
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }

    /// Encodes the control. Terminal entries stay in the legacy schema (no
    /// `type` key) so unchanged configs keep stable trust fingerprints; browser
    /// entries emit `type`/`url`. An empty `env` is omitted.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        switch kind {
        case .terminal:
            // Terminal entries are encoded exactly as the legacy schema (no
            // `type` key) so existing project-config trust fingerprints stay
            // stable for unchanged configs.
            guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                let context = EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.command],
                    debugDescription: "Dock control command must not be blank."
                )
                throw EncodingError.invalidValue(command as Any, context)
            }
            try container.encode(command, forKey: .command)
        case .browser:
            try container.encode(DockSurfaceKind.browser.rawValue, forKey: .type)
            guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else {
                let context = EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.url],
                    debugDescription: "Dock browser control url must not be blank."
                )
                throw EncodingError.invalidValue(url as Any, context)
            }
            try container.encode(url, forKey: .url)
        }
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(height, forKey: .height)
        if !env.isEmpty {
            try container.encode(env, forKey: .env)
        }
    }
}
