import Foundation

/// A single Dock control loaded from `dock.json`.
struct DockControlDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let variant: DockControlVariant
    let cwd: String?
    let height: Double?
    let env: [String: String]

    var surfaceKind: DockSurfaceKind {
        switch variant {
        case .command, .terminal:
            return .terminal
        case .browser:
            return .browser
        }
    }

    var command: String? {
        if case .command(let command) = variant { return command }
        return nil
    }

    var url: String? {
        if case .browser(let url, _) = variant { return url }
        return nil
    }

    var profile: String? {
        if case .browser(_, let profile) = variant { return profile }
        return nil
    }

    init(
        id: String,
        title: String,
        variant: DockControlVariant,
        cwd: String? = nil,
        height: Double? = nil,
        env: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.variant = variant
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
        case profile
        case cwd
        case height
        case env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw Self.validationError(
                code: 2,
                message: String(localized: "dock.error.blankControlID", defaultValue: "Dock control id must not be blank.")
            )
        }

        let rawType = try container.decodeIfPresent(String.self, forKey: .type)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedCommand = try container.decodeIfPresent(String.self, forKey: .command)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = try container.decodeIfPresent(String.self, forKey: .url)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProfile = try container.decodeIfPresent(String.self, forKey: .profile)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedVariant: DockControlVariant
        switch rawType {
        case .none, .some(""), .some("command"):
            guard let normalizedCommand, !normalizedCommand.isEmpty else {
                throw Self.validationError(
                    code: 4,
                    message: String(localized: "dock.error.blankControlCommand", defaultValue: "Dock control command must not be blank.")
                )
            }
            resolvedVariant = .command(normalizedCommand)
        case .some("terminal"):
            if let normalizedCommand, !normalizedCommand.isEmpty {
                resolvedVariant = .command(normalizedCommand)
            } else {
                resolvedVariant = .terminal
            }
        case .some("browser"):
            guard let normalizedURL, !normalizedURL.isEmpty else {
                throw Self.validationError(
                    code: 5,
                    message: String(localized: "dock.error.blankControlURL", defaultValue: "Dock browser control url must not be blank.")
                )
            }
            resolvedVariant = .browser(
                url: normalizedURL,
                profile: normalizedProfile.flatMap { $0.isEmpty ? nil : $0 }
            )
        default:
            throw Self.validationError(
                code: 3,
                message: String(localized: "dock.error.unknownControlType", defaultValue: "Dock control type must be command, terminal, or browser.")
            )
        }

        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? rawID
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        id = normalizedID
        title = normalizedTitle.isEmpty ? normalizedID : normalizedTitle
        variant = resolvedVariant
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        switch variant {
        case .command(let command):
            try container.encode(command, forKey: .command)
        case .terminal:
            try container.encode("terminal", forKey: .type)
        case .browser(let url, let profile):
            try container.encode("browser", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(profile, forKey: .profile)
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
