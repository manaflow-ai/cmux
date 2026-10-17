import Foundation

/// Turns JSON-with-comments (the devcontainer dialect) into strict JSON:
/// `//` and `/* */` comments outside strings are removed and a comma before `}` or `]`
/// is dropped. String contents are left untouched.
struct CloudSecretJSONC {
    let text: String

    var strictJSON: String {
        let characters = Array(text.unicodeScalars)
        var output: [Unicode.Scalar] = []
        var index = 0
        var inString = false
        var escaped = false
        // Index in `output` of a comma that is only valid if more values follow.
        var pendingComma: Int?
        while index < characters.count {
            let scalar = characters[index]
            if inString {
                output.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            let next: Unicode.Scalar? = index + 1 < characters.count ? characters[index + 1] : nil
            if scalar == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if scalar == "/", next == "*" {
                index += 2
                while index < characters.count, !(characters[index] == "*" && index + 1 < characters.count && characters[index + 1] == "/") {
                    index += 1
                }
                index += 2
                continue
            }
            if scalar == "}" || scalar == "]" {
                if let comma = pendingComma {
                    output[comma] = Unicode.Scalar(UInt8(0x20))
                }
                pendingComma = nil
            } else if scalar == "," {
                pendingComma = output.count
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingComma = nil
            }
            if scalar == "\"" { inString = true }
            output.append(scalar)
            index += 1
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: output)
        return String(result)
    }

    /// The parsed top-level object, or `nil` when the text is not a JSON object.
    func object() -> [String: Any]? {
        guard let data = strictJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}
