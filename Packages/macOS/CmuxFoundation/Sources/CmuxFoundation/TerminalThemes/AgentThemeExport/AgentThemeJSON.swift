import Foundation

/// A JSON value that keeps its keys in the order they were written.
///
/// Agent theme files are meant to be read and edited by people, so the
/// exporters emit tokens in the order each tool documents them instead of
/// sorted, and keep short `{ "dark": ..., "light": ... }` pairs on one line.
indirect enum AgentThemeJSON: Sendable {
    /// A JSON string.
    case string(String)
    /// A JSON object. `inline` renders it on one line.
    case object([(String, AgentThemeJSON)], inline: Bool)

    /// Pretty-printed JSON with two-space indentation and a trailing newline.
    func rendered() -> String {
        var output = ""
        write(into: &output, indent: 0)
        return output + "\n"
    }

    private func write(into output: inout String, indent: Int) {
        switch self {
        case .string(let value):
            output += Self.quoted(value)
        case .object(let members, let inline):
            guard !members.isEmpty else {
                output += "{}"
                return
            }
            if inline {
                output += "{ "
                for (offset, member) in members.enumerated() {
                    if offset > 0 { output += ", " }
                    output += Self.quoted(member.0) + ": "
                    member.1.write(into: &output, indent: indent)
                }
                output += " }"
                return
            }
            let padding = String(repeating: " ", count: indent + 2)
            output += "{\n"
            for (offset, member) in members.enumerated() {
                output += padding + Self.quoted(member.0) + ": "
                member.1.write(into: &output, indent: indent + 2)
                output += offset == members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: " ", count: indent) + "}"
        }
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
