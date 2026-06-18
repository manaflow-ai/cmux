import Foundation

/// Human-facing metadata for a catalog setting.
///
/// Metadata is attached to the setting key itself so CLI, socket, search, and
/// documentation surfaces can all derive their labels from the same catalog.
/// Callers may provide curated text, but generated fallbacks keep a newly added
/// setting discoverable even when no custom copy has been written yet.
public struct SettingMetadata: Sendable, Equatable {
    /// Short display title for the setting.
    public let title: String

    /// Optional explanatory text supplied by the key declaration.
    public let description: String?

    /// Creates metadata for a setting.
    ///
    /// - Parameters:
    ///   - id: The setting's dotted identifier.
    ///   - title: Optional display title. When omitted, one is generated from `id`.
    ///   - description: Optional explanatory text.
    public init(id: String, title: String? = nil, description: String? = nil) {
        self.title = Self.nonEmpty(title) ?? Self.generatedTitle(for: id)
        self.description = Self.nonEmpty(description)
    }

    /// Generates a stable title from a dotted setting id.
    ///
    /// The first dotted component is treated as the section and omitted when
    /// there is a more specific setting path, so `app.appearance` becomes
    /// `Appearance` while `terminal.agentHibernation.idleSeconds` becomes
    /// `Agent Hibernation Idle Seconds`.
    public static func generatedTitle(for id: String) -> String {
        let components = id
            .split(separator: ".")
            .map(String.init)
        let titleComponents = components.count > 1 ? Array(components.dropFirst()) : components
        let words = titleComponents.flatMap(words(in:))
        guard !words.isEmpty else { return id }
        return words.map(normalizedWord(_:)).joined(separator: " ")
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func words(in component: String) -> [String] {
        guard !component.isEmpty else { return [] }
        var words: [String] = []
        var current = ""
        let characters = Array(component)

        for index in characters.indices {
            let character = characters[index]
            if character == "-" || character == "_" {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                continue
            }

            if !current.isEmpty, shouldStartNewWord(
                previous: characters[characters.index(before: index)],
                current: character,
                next: characters.index(after: index) < characters.endIndex
                    ? characters[characters.index(after: index)]
                    : nil
            ) {
                words.append(current)
                current = ""
            }
            current.append(character)
        }

        if !current.isEmpty {
            words.append(current)
        }

        return mergeAcronymFragments(words)
    }

    private static func shouldStartNewWord(previous: Character, current: Character, next: Character?) -> Bool {
        if previous.isNumber, current.isLetter { return true }
        if previous.isLetter, current.isNumber { return true }
        if previous.isLowercase, current.isUppercase { return true }
        if previous.isUppercase, current.isUppercase, next?.isLowercase == true { return true }
        return false
    }

    private static func mergeAcronymFragments(_ words: [String]) -> [String] {
        var merged: [String] = []
        var index = 0
        while index < words.count {
            if index + 1 < words.count,
               words[index] == "i",
               words[index + 1] == "OS" {
                merged.append("iOS")
                index += 2
            } else {
                merged.append(words[index])
                index += 1
            }
        }
        return merged
    }

    private static func normalizedWord(_ word: String) -> String {
        let lowercased = word.lowercased()
        switch lowercased {
        case "api": return "API"
        case "cmd": return "Cmd"
        case "cwd": return "CWD"
        case "gpu": return "GPU"
        case "http": return "HTTP"
        case "https": return "HTTPS"
        case "ios": return "iOS"
        case "json": return "JSON"
        case "pii": return "PII"
        case "pr": return "PR"
        case "prs": return "PRs"
        case "ssh": return "SSH"
        case "ui": return "UI"
        case "url": return "URL"
        case "urls": return "URLs"
        case "wk": return "WK"
        default:
            return word.prefix(1).uppercased() + word.dropFirst()
        }
    }
}
