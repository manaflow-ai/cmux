import CmuxNextCompat
import Foundation

/// The JSON shapes ``ChromiumPageHostBridge`` reads and writes. Pure, so tests check each shape.
nonisolated struct ChromiumPageHostWire {
    /// A `Runtime.bindingCalled` event.
    struct BindingCall: Equatable {
        var name: String
        var payload: String
        var contextID: Int

        /// Nil unless `event` is a `Runtime.bindingCalled` message.
        init?(event: String) {
            guard let message = ChromiumPageHostWire.object(event), message["method"] as? String == "Runtime.bindingCalled",
                  let params = message["params"] as? [String: Any],
                  let name = params["name"] as? String, let payload = params["payload"] as? String,
                  let context = params["executionContextId"] as? Int
            else { return nil }
            self.name = name
            self.payload = payload
            contextID = context
        }
    }

    /// The page script's payload: `{name, seq?, body}`.
    struct Message {
        var name: String
        /// Set for the replying handler.
        var seq: Int?
        var body: Any

        init?(payload: String) {
            guard let object = ChromiumPageHostWire.object(payload), let name = object["name"] as? String,
                  let body = object["body"] else { return nil }
            let seq = object["seq"] as? Int
            if let seq, seq <= 0 { return nil }
            self.name = name
            self.seq = seq
            self.body = body
        }
    }

    /// The `Runtime.evaluate` result of `[location.href, window === window.top]`.
    struct Sender: Equatable {
        var url: URL?
        var isTop: Bool

        init(url: URL?, isTop: Bool) {
            self.url = url
            self.isTop = isTop
        }

        init?(evaluation json: String) {
            guard let object = ChromiumPageHostWire.object(json), object["exceptionDetails"] == nil,
                  let result = object["result"] as? [String: Any],
                  let value = result["value"] as? [Any], value.count == 2,
                  let href = value[0] as? String, let isTop = value[1] as? Bool
            else { return nil }
            url = URL(string: href)
            self.isTop = isTop
        }
    }

    /// The document event a raw DevTools event means: a main-frame `Page.frameNavigated` is a
    /// committed document, `Page.loadEventFired` a finished one; nil for any other message.
    static func documentEvent(_ json: String) -> PageChromiumEvent? {
        let method = DevToolsMessageHead(json: json).method
        guard method == "Page.frameNavigated" || method == "Page.loadEventFired",
              let object = object(json), object["id"] == nil, let method = object["method"] as? String else { return nil }
        switch method {
        case "Page.loadEventFired":
            return .finished
        case "Page.frameNavigated":
            guard let params = object["params"] as? [String: Any], let frame = params["frame"] as? [String: Any],
                  frame["parentId"] == nil else { return nil }
            let fragment = frame["urlFragment"] as? String ?? ""
            return .committed((frame["url"] as? String).flatMap { URL(string: $0 + fragment) })
        default:
            return nil
        }
    }

    /// Whether a `Runtime.evaluate` result (by value) is the boolean `true`.
    static func evaluationIsTrue(_ json: String) -> Bool {
        guard let object = object(json), object["exceptionDetails"] == nil,
              let result = object["result"] as? [String: Any] else { return false }
        return result["value"] as? Bool == true
    }

    /// The string a `Runtime.evaluate` with `returnByValue` returned, nil for an exception or
    /// another type.
    static func evaluationString(_ json: String) -> String? {
        guard let object = object(json), object["exceptionDetails"] == nil,
              let result = object["result"] as? [String: Any] else { return nil }
        return result["value"] as? String
    }

    static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A JavaScript string literal (JSON is a subset of JavaScript).
    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// The reply call: the reply as JSON (`null` for none); a reply that is not JSON becomes the
    /// host's failure envelope, so the page's promise still settles.
    static func resolveExpression(seq: Int, reply: Any?) -> String {
        let value: String
        if let reply, !(reply is NSNull) {
            // `JSONSerialization` raises an Objective-C exception (it does not throw) for a value
            // that is not JSON, such as a `Date`: check first, wrapped in an array so a bare string
            // or number counts too.
            let invalid = #"{"ok":false,"error":{"code":"native.invalid_reply","userMessage":"Invalid reply"}}"#
            value = JSONSerialization.isValidJSONObject([reply])
                ? (try? JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? invalid
                : invalid
        } else {
            value = "null"
        }
        return "globalThis.\(ChromiumPageHostBridge.resolveName)?.(\(seq), \(value));"
    }
}
