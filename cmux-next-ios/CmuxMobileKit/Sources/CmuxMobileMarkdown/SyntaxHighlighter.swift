#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// A small lexical highlighter for code cards (SPEC 2.1 syntax palette). It
/// recognises comments, strings, numbers, keywords, capitalised types and
/// calls; good enough for transcripts, cheap enough to run on the streaming tail.
public struct SyntaxHighlighter: Sendable {
    public var language: String?

    public init(language: String?) {
        self.language = language?.lowercased()
    }

    private var keywords: Set<String> {
        switch language {
        case "swift":
            ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "internal", "fileprivate", "static", "self", "Self", "init", "throws", "throw", "try", "await", "async", "for", "in", "while", "switch", "case", "default", "break", "continue", "nil", "true", "false", "some", "any", "where", "final", "override", "mutating", "actor", "defer", "do", "catch", "inout", "is", "as"]
        case "python", "py":
            ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "None", "True", "False", "and", "or", "not", "is", "pass", "yield", "async", "await", "self"]
        case "rust", "rs":
            ["fn", "let", "mut", "if", "else", "match", "return", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "for", "in", "while", "loop", "async", "await", "move", "ref", "true", "false", "where", "dyn", "const", "static", "unsafe", "as"]
        case "bash", "sh", "shell", "zsh", "console":
            ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "export", "local", "return", "in", "cd", "echo", "sudo"]
        default:
            ["function", "const", "let", "var", "if", "else", "return", "class", "import", "export", "from", "default", "new", "this", "for", "while", "in", "of", "async", "await", "try", "catch", "throw", "true", "false", "null", "undefined", "type", "interface", "extends", "implements", "public", "private", "static", "func", "struct", "fn", "def", "package", "go", "select"]
        }
    }

    private var lineComment: String {
        switch language {
        case "python", "py", "bash", "sh", "shell", "zsh", "yaml", "yml", "toml", "ruby", "rb": "#"
        default: "//"
        }
    }

    /// What a highlighted piece of code is.
    public enum Token: Sendable {
        case comment, string, number, keyword, function, type
    }

    /// `code` as pieces in order, each with its token (nil: plain text). Pure, so it runs off the main thread.
    public func pieces(_ code: String) -> [(text: String, token: Token?)] {
        var output: [(text: String, token: Token?)] = []
        let keywords = keywords
        let comment = lineComment
        let chars = Array(code)
        var index = 0
        var plain = ""
        func flushPlain() {
            if !plain.isEmpty {
                output.append((plain, nil))
                plain = ""
            }
        }
        func emit(_ text: String, _ token: Token) {
            flushPlain()
            output.append((text, token))
        }
        let commentChars = Array(comment)
        while index < chars.count {
            let c = chars[index]
            // Line comment.
            if c == commentChars[0], index + commentChars.count <= chars.count,
               Array(chars[index..<index + commentChars.count]) == commentChars {
                var end = index
                while end < chars.count, chars[end] != "\n" { end += 1 }
                emit(String(chars[index..<end]), .comment)
                index = end
                continue
            }
            // Strings.
            if c == "\"" || c == "'" || c == "`" {
                var end = index + 1
                while end < chars.count, chars[end] != c, chars[end] != "\n" {
                    if chars[end] == "\\" { end += 1 }
                    end += 1
                }
                end = min(end + 1, chars.count)
                emit(String(chars[index..<end]), .string)
                index = end
                continue
            }
            // Numbers.
            if c.isNumber, index == 0 || !(chars[index - 1].isLetter || chars[index - 1] == "_") {
                var end = index
                while end < chars.count, chars[end].isNumber || chars[end] == "." || chars[end] == "_" || chars[end] == "x" { end += 1 }
                emit(String(chars[index..<end]), .number)
                index = end
                continue
            }
            // Words.
            if c.isLetter || c == "_" || c == "@" || c == "#" {
                var end = index + 1
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
                let word = String(chars[index..<end])
                if keywords.contains(word) || word.hasPrefix("@") || (word.hasPrefix("#") && word.count > 1 && language == "swift") {
                    emit(word, .keyword)
                } else if end < chars.count, chars[end] == "(" {
                    emit(word, .function)
                } else if let first = word.first, first.isUppercase {
                    emit(word, .type)
                } else {
                    plain += word
                }
                index = end
                continue
            }
            plain.append(c)
            index += 1
        }
        flushPlain()
        return output
    }

    public func highlight(_ code: String) -> AttributedString {
        var output = AttributedString()
        for piece in pieces(code) {
            var run = AttributedString(piece.text)
            if let token = piece.token { run.foregroundColor = Self.color(token) }
            output += run
        }
        return output
    }

    static func color(_ token: Token) -> Color {
        switch token {
        case .comment: .cmuxMobileSyntaxComment
        case .string: .cmuxMobileSyntaxString
        case .number: .cmuxMobileSyntaxNumber
        case .keyword: .cmuxMobileSyntaxKeyword
        case .function: .cmuxMobileSyntaxFunction
        case .type: .cmuxMobileSyntaxType
        }
    }

    /// The same palette as UIKit colors.
    public static func uiColor(_ token: Token) -> UIColor {
        switch token {
        case .comment: .cmuxMobileSyntaxComment
        case .string: .cmuxMobileSyntaxString
        case .number: .cmuxMobileSyntaxNumber
        case .keyword: .cmuxMobileSyntaxKeyword
        case .function: .cmuxMobileSyntaxFunction
        case .type: .cmuxMobileSyntaxType
        }
    }
}
#endif
