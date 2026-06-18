#if DEBUG
import Foundation

struct TerminalAccessibilityTextFallback {
    private init() {}

    static func text(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let stripped = stripControlSequences(from: text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    private static func stripControlSequences(from text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let escape = UnicodeScalar(0x1B)!
        let bell = UnicodeScalar(0x07)!
        let backslash = UnicodeScalar(0x5C)!
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == escape else {
                output.append(scalar)
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else { break }
            let introducer = scalars[index]

            if introducer == "[" {
                index += 1
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if value >= 0x40 && value <= 0x7E {
                        break
                    }
                }
                continue
            }

            if introducer == "]" {
                index += 1
                while index < scalars.count {
                    if scalars[index] == bell {
                        index += 1
                        break
                    }
                    if scalars[index] == escape,
                       index + 1 < scalars.count,
                       scalars[index + 1] == backslash {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }

            index += 1
        }

        return String(output)
    }
}
#endif
