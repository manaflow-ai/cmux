import Foundation

enum CmuxUnicodeSanitizer {
    static let dangerousScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{FEFF}",
    ]

    static func removingDangerousScalars(from text: String) -> String {
        String(text.unicodeScalars.filter { !dangerousScalars.contains($0) })
    }

    static func trimmed(_ text: String) -> String {
        removingDangerousScalars(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CmuxPromptSnippetDefinition: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var text: String
    var description: String?
    var keywords: [String]
    var idWasGenerated: Bool // Not encoded; recomputed on decode.

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case text
        case prompt
        case content
        case body
        case description
        case keywords
    }

    init(
        id: String? = nil,
        title: String,
        text: String,
        description: String? = nil,
        keywords: [String] = []
    ) {
        let sanitizedTitle = Self.sanitizedString(title)
        let explicitID = id.map(Self.sanitizedString).flatMap { $0.isEmpty ? nil : $0 }
        if let explicitID {
            self.id = explicitID
            idWasGenerated = false
        } else {
            self.id = Self.generatedID(for: sanitizedTitle)
            idWasGenerated = true
        }
        self.title = sanitizedTitle
        self.text = Self.removingDangerousScalars(from: text)
        self.description = description.map(Self.sanitizedString).flatMap { $0.isEmpty ? nil : $0 }
        self.keywords = Self.sanitizedKeywords(keywords)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try Self.firstTrimmedString(
            keys: [.title, .name],
            in: container,
            debugName: "promptSnippets entries require title or name"
        )
        let text = try Self.firstNonBlankString(
            keys: [.text, .prompt, .content, .body],
            in: container,
            debugName: "promptSnippets entries require text, prompt, content, or body"
        )
        let explicitID = try Self.trimmedString(forKey: .id, in: container, allowBlankAsNil: true)
        let description = try Self.trimmedString(forKey: .description, in: container, allowBlankAsNil: true)
        let keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []

        self.init(
            id: explicitID,
            title: title,
            text: text,
            description: description,
            keywords: keywords
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(description, forKey: .description)
        if !keywords.isEmpty {
            try container.encode(keywords, forKey: .keywords)
        }
    }

    static func == (lhs: CmuxPromptSnippetDefinition, rhs: CmuxPromptSnippetDefinition) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.text == rhs.text
            && lhs.description == rhs.description
            && lhs.keywords == rhs.keywords
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(text)
        hasher.combine(description)
        hasher.combine(keywords)
    }

    private static func firstTrimmedString(
        keys: [CodingKeys],
        in container: KeyedDecodingContainer<CodingKeys>,
        debugName: String
    ) throws -> String {
        for key in keys {
            if let value = try trimmedString(forKey: key, in: container, allowBlankAsNil: true) {
                return value
            }
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: debugName
            )
        )
    }

    private static func firstNonBlankString(
        keys: [CodingKeys],
        in container: KeyedDecodingContainer<CodingKeys>,
        debugName: String
    ) throws -> String {
        for key in keys where container.contains(key) {
            let raw = try container.decode(String.self, forKey: key)
            let sanitized = removingDangerousScalars(from: raw)
            guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return sanitized
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: debugName
            )
        )
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = sanitizedString(raw)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }

    private static func sanitizedKeywords(_ rawKeywords: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for keyword in rawKeywords {
            let sanitized = sanitizedString(keyword)
            guard !sanitized.isEmpty else { continue }
            let key = sanitized.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: stableLocale).lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(sanitized)
        }
        return result
    }

    private static let stableLocale = Locale(identifier: "en_US_POSIX")

    private static func removingDangerousScalars(from text: String) -> String {
        CmuxUnicodeSanitizer.removingDangerousScalars(from: text)
    }

    private static func sanitizedString(_ text: String) -> String {
        CmuxUnicodeSanitizer.trimmed(text)
    }

    private static func generatedID(for title: String) -> String {
        let normalized = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: stableLocale)
            .lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var slug = ""
        var previousWasSeparator = false
        for scalar in normalized.unicodeScalars {
            if allowed.contains(scalar) {
                slug.append(String(scalar))
                previousWasSeparator = false
            } else if !previousWasSeparator {
                slug.append("-")
                previousWasSeparator = true
            }
        }
        let trimmedSlug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmedSlug.isEmpty ? "prompt-snippet" : trimmedSlug
    }
}

struct CmuxResolvedPromptSnippet: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var text: String
    var description: String?
    var keywords: [String]
    var sourcePath: String?

    var commandPaletteCommandID: String {
        "palette.promptSnippet.\(Self.commandPaletteCommandIDToken(for: id))"
    }

    init(definition: CmuxPromptSnippetDefinition, sourcePath: String?) {
        id = definition.id
        title = definition.title
        text = definition.text
        description = definition.description
        keywords = definition.keywords
        self.sourcePath = sourcePath
    }

    private static func commandPaletteCommandIDToken(for id: String) -> String {
        var encoded = ""
        for byte in id.utf8 {
            switch byte {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                encoded.append(String(UnicodeScalar(UInt32(byte))!))
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded.isEmpty ? "prompt-snippet" : encoded
    }
}
