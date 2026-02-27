import Foundation
import STPluginNeon
import TreeSitterResource

enum LanguageDetection {

    /// Map file extension to Plugin-Neon's TreeSitterLanguage (20 languages supported).
    static func treeSitterLanguage(forFilePath path: String) -> TreeSitterLanguage? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh":              return .bash
        case "c", "h":                         return .c
        case "cpp", "cc", "cxx", "hpp", "hxx": return .cpp
        case "cs":                             return .csharp
        case "css":                            return .css
        case "go":                             return .go
        case "html", "htm":                    return .html
        case "java":                           return .java
        case "js", "mjs", "cjs":               return .javascript
        case "json", "jsonc":                  return .json
        case "md", "markdown":                 return .markdown
        case "php":                            return .php
        case "py", "pyw":                      return .python
        case "rb":                             return .ruby
        case "rs":                             return .rust
        case "swift":                          return .swift
        case "sql":                            return .sql
        case "toml":                           return .toml
        case "ts", "mts", "cts":               return .typescript
        case "yaml", "yml":                    return .yaml
        default:                               return nil
        }
    }

    /// Display name for the header bar badge.
    static func languageName(forFilePath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh":              return "Bash"
        case "c", "h":                         return "C"
        case "cpp", "cc", "cxx", "hpp", "hxx": return "C++"
        case "cs":                             return "C#"
        case "css":                            return "CSS"
        case "dart":                           return "Dart"
        case "dockerfile":                     return "Dockerfile"
        case "ex", "exs":                      return "Elixir"
        case "go":                             return "Go"
        case "hs":                             return "Haskell"
        case "html", "htm":                    return "HTML"
        case "java":                           return "Java"
        case "js", "mjs", "cjs":               return "JavaScript"
        case "json", "jsonc":                  return "JSON"
        case "jsx":                            return "JSX"
        case "kt", "kts":                      return "Kotlin"
        case "lua":                            return "Lua"
        case "md", "markdown":                 return "Markdown"
        case "m":                              return "Objective-C"
        case "ml", "mli":                      return "OCaml"
        case "pl", "pm":                       return "Perl"
        case "php":                            return "PHP"
        case "py", "pyw":                      return "Python"
        case "rb":                             return "Ruby"
        case "rs":                             return "Rust"
        case "scala":                          return "Scala"
        case "sql":                            return "SQL"
        case "swift":                          return "Swift"
        case "toml":                           return "TOML"
        case "tsx":                            return "TSX"
        case "ts", "mts", "cts":               return "TypeScript"
        case "yaml", "yml":                    return "YAML"
        case "zig":                            return "Zig"
        case "xml", "svg", "plist":            return "XML"
        case "txt":                            return "Plain Text"
        case "cfg", "conf", "ini":             return "Config"
        case "makefile":                       return "Makefile"
        default:
            // Check filename-based detection
            let name = (path as NSString).lastPathComponent.lowercased()
            switch name {
            case "makefile", "gnumakefile":    return "Makefile"
            case "dockerfile":                 return "Dockerfile"
            case ".gitignore", ".gitattributes": return "Git Config"
            case ".env":                       return "Env"
            default:                           return nil
            }
        }
    }
}
