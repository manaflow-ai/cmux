import Foundation
import SwiftTreeSitter
import CodeEditLanguages

enum LanguageDetection {
    private static var configCache: [TreeSitterLanguage: LanguageConfiguration] = [:]
    private static let cacheLock = NSLock()

    static func languageConfiguration(forFilePath path: String) -> LanguageConfiguration? {
        let url = URL(fileURLWithPath: path)
        let codeLang = CodeLanguage.detectLanguageFrom(url: url)

        guard codeLang.id != .plainText,
              let language = codeLang.language,
              let queryURL = codeLang.queryURL else {
            return nil
        }

        cacheLock.lock()
        if let cached = configCache[codeLang.id] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let queriesDirectory = queryURL.deletingLastPathComponent()
        guard let config = try? LanguageConfiguration(language, name: codeLang.tsName, queriesURL: queriesDirectory) else {
            return nil
        }

        cacheLock.lock()
        configCache[codeLang.id] = config
        cacheLock.unlock()

        return config
    }

    static func languageName(forFilePath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let codeLang = CodeLanguage.detectLanguageFrom(url: url)
        guard codeLang.id != .plainText else { return nil }
        return displayName(for: codeLang)
    }

    private static func displayName(for lang: CodeLanguage) -> String {
        switch lang.id {
        case .bash: return "Bash"
        case .c: return "C"
        case .cpp: return "C++"
        case .cSharp: return "C#"
        case .css: return "CSS"
        case .dart: return "Dart"
        case .dockerfile: return "Dockerfile"
        case .elixir: return "Elixir"
        case .go: return "Go"
        case .goMod: return "Go Mod"
        case .haskell: return "Haskell"
        case .html: return "HTML"
        case .java: return "Java"
        case .javascript: return "JavaScript"
        case .jsdoc: return "JSDoc"
        case .json: return "JSON"
        case .jsx: return "JSX"
        case .kotlin: return "Kotlin"
        case .lua: return "Lua"
        case .markdown: return "Markdown"
        case .objc: return "Objective-C"
        case .ocaml: return "OCaml"
        case .perl: return "Perl"
        case .php: return "PHP"
        case .python: return "Python"
        case .regex: return "Regex"
        case .ruby: return "Ruby"
        case .rust: return "Rust"
        case .scala: return "Scala"
        case .sql: return "SQL"
        case .swift: return "Swift"
        case .toml: return "TOML"
        case .tsx: return "TSX"
        case .typescript: return "TypeScript"
        case .yaml: return "YAML"
        case .zig: return "Zig"
        default: return lang.tsName.capitalized
        }
    }
}
