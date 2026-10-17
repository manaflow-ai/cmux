import Foundation

/// Text for a DevTools `Runtime.RemoteObject`, close to what the JavaScript
/// bootstrap writes for a console argument: strings as they are, other
/// values as JSON when the protocol's preview allows it.
enum BrowserProtocolRemoteObjectText {
    static func text(of object: [String: Any]) -> String {
        let type = object["type"] as? String ?? ""
        switch type {
        case "string":
            return object["value"] as? String ?? ""
        case "undefined":
            return "undefined"
        case "number", "boolean", "bigint":
            if let description = object["description"] as? String { return description }
            if let unserializable = object["unserializableValue"] as? String { return unserializable }
            return object["value"].map { "\($0)" } ?? ""
        case "object":
            if object["subtype"] as? String == "null" { return "null" }
            if let preview = object["preview"] as? [String: Any],
               ["array", nil].contains(object["subtype"] as? String),
               let text = previewText(preview) {
                return text
            }
            return object["description"] as? String ?? object["className"] as? String ?? "Object"
        default:
            return object["description"] as? String ?? ""
        }
    }

    /// `{"a":1}` or `[1,"x"]` from an object or array preview.
    private static func previewText(_ preview: [String: Any]) -> String? {
        guard let properties = preview["properties"] as? [[String: Any]] else { return nil }
        let isArray = preview["subtype"] as? String == "array"
        var parts: [String] = []
        for property in properties {
            let value = valueText(property)
            if isArray {
                parts.append(value)
            } else {
                parts.append("\(quoted(property["name"] as? String ?? "")):\(value)")
            }
        }
        if preview["overflow"] as? Bool == true { parts.append("…") }
        let body = parts.joined(separator: ",")
        return isArray ? "[\(body)]" : "{\(body)}"
    }

    private static func valueText(_ property: [String: Any]) -> String {
        let value = property["value"] as? String ?? ""
        switch property["type"] as? String {
        case "string": return quoted(value)
        case "number", "boolean": return value
        case "undefined": return "null"
        case "object": return property["subtype"] as? String == "null" ? "null" : value
        default: return value
        }
    }

    private static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8) else { return "\"\(text)\"" }
        return String(array.dropFirst().dropLast())
    }
}
