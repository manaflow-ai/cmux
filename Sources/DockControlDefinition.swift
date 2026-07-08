import Foundation

/// A single Dock control loaded from `dock.json`.
struct DockControlDefinition: Codable, Equatable, Identifiable, Sendable {
    static let maximumEnvironmentVariableCount = 64
    static let maximumTextFieldByteCount = 4096

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
        try Self.validateTextField(rawID)
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw Self.validationError(
                code: 2,
                message: String(localized: "dock.error.blankControlID", defaultValue: "Dock control id must not be blank.")
            )
        }

        let decodedType = try container.decodeIfPresent(String.self, forKey: .type)
        if let decodedType { try Self.validateTextField(decodedType) }
        let rawType = decodedType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rawCommand = try container.decodeIfPresent(String.self, forKey: .command)
        if let rawCommand { try Self.validateTextField(rawCommand) }
        let normalizedCommand = rawCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = try container.decodeIfPresent(String.self, forKey: .url)
        if let rawURL { try Self.validateTextField(rawURL) }
        let normalizedURL = rawURL?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawProfile = try container.decodeIfPresent(String.self, forKey: .profile)
        if let rawProfile { try Self.validateTextField(rawProfile) }
        let normalizedProfile = rawProfile?
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
            if let normalizedCommand {
                guard !normalizedCommand.isEmpty else {
                    throw Self.validationError(
                        code: 4,
                        message: String(localized: "dock.error.blankControlCommand", defaultValue: "Dock control command must not be blank.")
                    )
                }
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
        try Self.validateTextField(rawTitle)
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        id = normalizedID
        title = normalizedTitle.isEmpty ? normalizedID : normalizedTitle
        variant = resolvedVariant
        let rawCWD = try container.decodeIfPresent(String.self, forKey: .cwd)
        if let rawCWD { try Self.validateTextField(rawCWD) }
        cwd = rawCWD?.trimmingCharacters(in: .whitespacesAndNewlines)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        env = try Self.decodeEnvironment(from: container)
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

    private static func decodeEnvironment(from container: KeyedDecodingContainer<CodingKeys>) throws -> [String: String] {
        guard container.contains(.env) else {
            return [:]
        }
        if try container.decodeNil(forKey: .env) { return [:] }

        let environmentContainer = try container.nestedContainer(keyedBy: DockControlEnvironmentCodingKey.self, forKey: .env)
        let environmentKeys = environmentContainer.allKeys
        guard environmentKeys.count <= Self.maximumEnvironmentVariableCount else {
            throw Self.validationError(
                code: 9,
                message: String(
                    format: String(
                        localized: "dock.error.tooManyEnvironmentVariables",
                        defaultValue: "Dock control env supports at most %lld variables."
                    ),
                    Int64(Self.maximumEnvironmentVariableCount)
                )
            )
        }

        var decodedEnvironment: [String: String] = [:]
        decodedEnvironment.reserveCapacity(environmentKeys.count)
        for key in environmentKeys {
            try Self.validateTextField(key.stringValue)
            let value = try environmentContainer.decode(String.self, forKey: key)
            try Self.validateTextField(value)
            decodedEnvironment[key.stringValue] = value
        }
        return decodedEnvironment
    }

    private static func validateTextField(_ value: String) throws {
        guard value.utf8.count <= Self.maximumTextFieldByteCount else {
            throw Self.validationError(
                code: 10,
                message: String(
                    format: String(
                        localized: "dock.error.textFieldTooLong",
                        defaultValue: "Dock control text fields must be at most %lld bytes."
                    ),
                    Int64(Self.maximumTextFieldByteCount)
                )
            )
        }
    }

}
