import CmuxSwiftRender
import Foundation

/// Converts JavaScript action payloads into the existing sidebar action model.
struct CustomSidebarWebActionParser {
    func action(from body: Any) -> ButtonAction? {
        if let action = body as? [String: Any], let commands = action["commands"] as? [Any] {
            let parsed = commands.compactMap(command(from:))
            return parsed.isEmpty ? nil : ButtonAction(commands: parsed)
        }
        return command(from: body).map { ButtonAction(commands: [$0]) }
    }

    private func command(from value: Any) -> ActionCommand? {
        guard let payload = value as? [String: Any] else { return nil }
        let type = (payload["type"] as? String) ?? (payload["kind"] as? String)
        switch type {
        case "log":
            return .log(stringValue(payload["message"]) ?? "")
        case "open", "openURL":
            return .openURL(stringValue(payload["url"]) ?? stringValue(payload["message"]) ?? "")
        case "cmux":
            guard let method = stringValue(payload["method"]) else { return nil }
            return .cmux(method: method, params: params(from: payload["params"]))
        case nil:
            guard let method = stringValue(payload["method"]) else { return nil }
            return .cmux(method: method, params: params(from: payload["params"]))
        default:
            guard let method = type else { return nil }
            return .cmux(method: method, params: params(from: payload["params"]))
        }
    }

    private func params(from value: Any?) -> [String: String] {
        guard let values = value as? [String: Any] else { return [:] }
        var params: [String: String] = [:]
        for (key, value) in values {
            if let string = stringValue(value) {
                params[key] = string
            }
        }
        return params
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
