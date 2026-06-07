#if DEBUG
import Foundation

struct DebugAccessibilityFallbackText {
    static func from(_ data: Data) -> String? {
        let decoded = String(decoding: data, as: UTF8.self)
        let text = stripTerminalControlSequences(decoded)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func stripTerminalControlSequences(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                scalars.formIndex(after: &index)
                guard index < scalars.endIndex else { break }
                let introducer = scalars[index]
                if introducer == "[" {
                    repeat {
                        scalars.formIndex(after: &index)
                    } while index < scalars.endIndex && !(0x40...0x7E).contains(scalars[index].value)
                    if index < scalars.endIndex {
                        scalars.formIndex(after: &index)
                    }
                } else if introducer == "]" {
                    var previousWasEscape = false
                    scalars.formIndex(after: &index)
                    while index < scalars.endIndex {
                        let oscScalar = scalars[index]
                        if oscScalar.value == 0x07 {
                            scalars.formIndex(after: &index)
                            break
                        }
                        if previousWasEscape, oscScalar == "\\" {
                            scalars.formIndex(after: &index)
                            break
                        }
                        previousWasEscape = oscScalar.value == 0x1B
                        scalars.formIndex(after: &index)
                    }
                } else {
                    scalars.formIndex(after: &index)
                }
                continue
            }

            if scalar.value < 0x20,
               scalar != "\n",
               scalar != "\r",
               scalar != "\t" {
                scalars.formIndex(after: &index)
                continue
            }

            result.append(scalar)
            scalars.formIndex(after: &index)
        }
        return String(result)
    }
}
#endif
