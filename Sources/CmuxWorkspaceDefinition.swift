import Foundation

struct CmuxWorkspaceDefinition: Codable, Sendable {
    var name: String?
    var cwd: String?
    var color: String?
    var layout: CmuxLayoutNode?

    init(name: String? = nil, cwd: String? = nil, color: String? = nil, layout: CmuxLayoutNode? = nil) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        layout = try container.decodeIfPresent(CmuxLayoutNode.self, forKey: .layout)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            let defaults = decoder.userInfo[.cmuxWorkspaceColorDefaults] as? UserDefaults ?? .standard
            guard let normalized = WorkspaceTabColorSettings.resolvedColorHex(rawColor, defaults: defaults) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "Invalid color \"\(rawColor)\". Expected 6-digit hex format (#RRGGBB) or a workspace color name"
                )
            }
            color = normalized
        } else {
            color = nil
        }
    }
}

struct CmuxWorkspacePresetDefinition: Codable, Sendable {
    static let currentSchema = "cmux.workspacePreset.v1"

    var schema: String
    var name: String
    var workspace: CmuxWorkspaceDefinition

    enum CodingKeys: String, CodingKey {
        case schema
        case name
        case workspace
    }

    init(
        schema: String = Self.currentSchema,
        name: String,
        workspace: CmuxWorkspaceDefinition
    ) {
        self.schema = schema
        self.name = name
        self.workspace = workspace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? Self.currentSchema
        name = try Self.validatedPresetName(
            try container.decode(String.self, forKey: .name),
            codingPath: container.codingPath + [CodingKeys.name]
        )
        workspace = try container.decode(CmuxWorkspaceDefinition.self, forKey: .workspace)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchema, forKey: .schema)
        try container.encode(name, forKey: .name)
        try container.encode(workspace, forKey: .workspace)
    }

    static func normalizedPresetName(_ raw: String?, fallbackName: String = "workspace") -> String {
        let candidates: [String?] = [
            raw,
            raw.map(Self.sanitizedPresetNameComponent),
            fallbackName,
            Self.sanitizedPresetNameComponent(fallbackName),
            "workspace"
        ]

        for candidate in candidates {
            if let valid = validPresetName(candidate) {
                return valid
            }
        }
        return "workspace"
    }

    static func sanitizedPresetNameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "workspace" : trimmed
    }

    private static func validPresetName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard !trimmed.hasPrefix(".") else { return nil }
        guard !trimmed.contains("..") else { return nil }
        return trimmed
    }

    private static func validatedPresetName(_ raw: String, codingPath: [CodingKey]) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Preset name must not be empty"
            ))
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Preset names may contain only letters, numbers, '.', '_', and '-'"
            ))
        }

        guard !trimmed.hasPrefix(".") else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Preset names may not start with '.'"
            ))
        }

        guard !trimmed.contains("..") else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Preset names may not contain '..'"
            ))
        }

        return trimmed
    }
}
