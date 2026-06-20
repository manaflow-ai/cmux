#if DEBUG
/// A minimal forward cursor over a JSON response prefix that reports the
/// top-level `error`/`ok` status without fully decoding the document.
///
/// This is the faithful lift of `TerminalController`'s hand-written
/// `topLevelJSONResponseStatus`/`scanJSONString`/`skipJSONValue`/
/// `skipJSONContainer`/`skipJSONWhitespace` family. The legacy code threaded a
/// shared `index: inout String.Index` through a set of static functions; here
/// the cursor is the struct's own stored state and each former function is a
/// `mutating` method, turning the static-namespace shape into a real value
/// type. Behavior, including the deliberate early-outs and the `ok:true`/
/// `ok:false`/`error` precedence, is byte-identical to the legacy scanner.
///
/// Used only by ``ControlSocketCommandLog/status(forResponse:)`` to classify a
/// v2 JSON response for the debug log; it is not a general JSON parser.
struct JSONResponseStatusScanner {
    private let text: Substring
    private var index: String.Index

    /// Creates a scanner positioned at the start of `text`.
    /// - Parameter text: The JSON response prefix to scan.
    init(text: Substring) {
        self.text = text
        self.index = text.startIndex
    }

    /// Reports the top-level status of a JSON response prefix.
    /// - Parameter text: The (already length-capped) response prefix.
    /// - Returns: `"error"` when the object's top-level `error` key is present
    ///   or `ok` is `false`, `"ok"` when `ok` is `true`, otherwise `nil`.
    static func topLevelStatus(in text: Substring) -> String? {
        var scanner = JSONResponseStatusScanner(text: text)
        return scanner.topLevelStatus()
    }

    private mutating func topLevelStatus() -> String? {
        skipWhitespace()
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex {
            skipWhitespace()
            if index >= text.endIndex { return nil }
            if text[index] == "}" { return nil }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            guard text[index] == "\"",
                  let key = scanString() else {
                return nil
            }
            skipWhitespace()
            guard index < text.endIndex, text[index] == ":" else { return nil }
            index = text.index(after: index)
            skipWhitespace()

            if key == "error" {
                return "error"
            }
            if key == "ok" {
                if text[index...].hasPrefix("false") {
                    return "error"
                }
                if text[index...].hasPrefix("true") {
                    return "ok"
                }
            }
            guard skipValue() else {
                return nil
            }
        }
        return nil
    }

    private mutating func scanString() -> String? {
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var result = ""
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isEscaped {
                result.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" {
                return result
            }
            result.append(char)
        }
        return nil
    }

    private mutating func skipValue() -> Bool {
        guard index < text.endIndex else { return false }
        switch text[index] {
        case "\"":
            return scanString() != nil
        case "{", "[":
            return skipContainer()
        default:
            while index < text.endIndex {
                switch text[index] {
                case ",", "}":
                    return true
                default:
                    index = text.index(after: index)
                }
            }
            return true
        }
    }

    private mutating func skipContainer() -> Bool {
        guard index < text.endIndex else { return false }
        let opener = text[index]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 1
        index = text.index(after: index)
        var isInString = false
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    isInString = false
                }
                continue
            }
            if char == "\"" {
                isInString = true
            } else if char == opener {
                depth += 1
            } else if char == closer {
                depth -= 1
                if depth == 0 {
                    return true
                }
            }
        }
        return false
    }

    private mutating func skipWhitespace() {
        while index < text.endIndex {
            switch text[index] {
            case " ", "\t", "\n", "\r":
                index = text.index(after: index)
            default:
                return
            }
        }
    }
}
#endif
