import AppKit
import Highlightr
import MarkdownUI
import SwiftUI

/// MarkdownUI syntax highlighter backed by Highlightr/highlight.js.
/// Supports a broad set of languages via highlight.js and falls back to
/// automatic language detection when the fenced language is unknown.
struct CMUXMarkdownCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private final class Storage {
        let highlightr: Highlightr?

        init(themeName: String) {
            let highlightr = Highlightr()
            highlightr?.setTheme(to: themeName)
            highlightr?.theme.setCodeFont(.monospacedSystemFont(ofSize: 13, weight: .regular))
            self.highlightr = highlightr
        }
    }

    private static let darkStorage = Storage(themeName: "atom-one-dark")
    private static let lightStorage = Storage(themeName: "xcode")

    private let storage: Storage

    init(colorScheme: ColorScheme) {
        self.storage = colorScheme == .dark ? Self.darkStorage : Self.lightStorage
    }

    func highlightCode(_ code: String, language: String?) -> Text {
        guard let highlightr = storage.highlightr else {
            return Text(code)
        }

        let normalizedLanguage = Self.normalizedLanguageName(language)
        let highlighted = highlightr.highlight(code, as: normalizedLanguage) ?? highlightr.highlight(code)
        guard let highlighted else {
            return Text(code)
        }

        guard let attributed = try? AttributedString(highlighted, including: \.appKit) else {
            return Text(code)
        }
        return Text(attributed)
    }

    private static func normalizedLanguageName(_ language: String?) -> String? {
        guard let language = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !language.isEmpty
        else {
            return nil
        }

        switch language {
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "sh", "shell", "zsh":
            return "bash"
        case "c++":
            return "cpp"
        case "cs", "c#":
            return "csharp"
        case "objc":
            return "objectivec"
        case "yml":
            return "yaml"
        case "kt":
            return "kotlin"
        default:
            return language
        }
    }
}

