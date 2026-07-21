import Foundation

/// A single Dock control loaded from `dock.json`.
///
/// Back-compat: existing terminal-only configs omit `type`/`url` and require
/// `command`; those decode unchanged as `.terminal` entries. New configs may add
/// `"type": "browser"` with a `url` to seed a browser pane. Floating Dock
/// content may also use `"type": "note"`; top-level right-Dock controls reject it.
struct DockControlDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: DockSurfaceKind
    let command: String?
    let url: String?
    let cwd: String?
    let height: Double?
    let env: [String: String]

    init(
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case title
        case type
        case command
        case url
        case cwd
        case height
        case env
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownDockConfigKeys(
            allowedKeys: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw Self.validationError(
                code: 2,
                message: String(localized: "dock.error.blankControlID", defaultValue: "Dock control id must not be blank.")
            )
        }

        let resolvedKind: DockSurfaceKind
        if let rawType = try container.decodeIfPresent(String.self, forKey: .type)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawType.isEmpty {
            guard let parsed = DockSurfaceKind(rawValue: rawType) else {
                throw Self.validationError(
                    code: 3,
                    message: String(localized: "dock.error.unknownContentType", defaultValue: "Dock content type must be terminal, browser, or note.")
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
                throw Self.validationError(
                    code: 4,
                    message: String(localized: "dock.error.blankControlCommand", defaultValue: "Dock control command must not be blank.")
                )
            }
            command = normalizedCommand
            url = nil
        case .browser:
            guard let normalizedURL, !normalizedURL.isEmpty else {
                throw Self.validationError(
                    code: 5,
                    message: String(localized: "dock.error.blankControlURL", defaultValue: "Dock browser control url must not be blank.")
                )
            }
            url = normalizedURL
            command = nil
        case .note:
            let unsupportedKeys: [CodingKeys] = [.command, .url, .cwd, .height, .env]
            guard !unsupportedKeys.contains(where: container.contains) else {
                throw Self.validationError(
                    code: 6,
                    message: String(
                        localized: "dock.error.noteFieldsUnsupported",
                        defaultValue: "Dock note content cannot include command, url, cwd, height, or env."
                    )
                )
            }
            command = nil
            url = nil
        }

        id = normalizedID
        title = normalizedTitle.isEmpty ? normalizedID : normalizedTitle
        kind = resolvedKind
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
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
                    debugDescription: String(localized: "dock.error.blankControlCommand", defaultValue: "Dock control command must not be blank.")
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
                    debugDescription: String(localized: "dock.error.blankControlURL", defaultValue: "Dock browser control url must not be blank.")
                )
                throw EncodingError.invalidValue(url as Any, context)
            }
            try container.encode(url, forKey: .url)
        case .note:
            guard command == nil, url == nil, cwd == nil, height == nil, env.isEmpty else {
                let context = EncodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: String(
                        localized: "dock.error.noteFieldsUnsupported",
                        defaultValue: "Dock note content cannot include command, url, cwd, height, or env."
                    )
                )
                throw EncodingError.invalidValue(self, context)
            }
            try container.encode(DockSurfaceKind.note.rawValue, forKey: .type)
        }
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(height, forKey: .height)
        if !env.isEmpty {
            try container.encode(env, forKey: .env)
        }
    }

    private static func validationError(code: Int, message: String) -> NSError {
        NSError(
            domain: "cmux.dock",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
