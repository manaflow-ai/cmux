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

    /// One message of the page script: `{name, seq?, doc?, body}`.
    struct Message {
        var name: String
        /// Set for the replying handler.
        var seq: Int?
        /// The sending document's token. Every document numbers its calls from 1, so a reply
        /// (``resolveExpression(seq:reply:document:)``, ``replyPush(seq:doc:reply:)``) names the
        /// document it answers.
        var doc: String?
        var body: Any

        init?(payload: String) {
            guard let object = ChromiumPageHostWire.object(payload) else { return nil }
            self.init(object: object)
        }

        init?(object: [String: Any]) {
            guard let name = object["name"] as? String, let body = object["body"] else { return nil }
            let seq = object["seq"] as? Int
            if let seq, seq <= 0 { return nil }
            self.name = name
            self.seq = seq
            doc = object["doc"] as? String
            self.body = body
        }
    }

    /// The messages of one post: one message, or a JSON array of them (the posts of one task,
    /// ``ChromiumPageHostBridge/pageScript(handlers:channelEvent:)``). Nil when it is neither, or
    /// when any element is not a message: the post is refused whole.
    static func messages(payload: String) -> [Message]? {
        guard let data = payload.data(using: .utf8),
              let value = try? JSONSerialization.blockingJSONObject(with: data) else { return nil }
        if let object = value as? [String: Any] { return Message(object: object).map { [$0] } }
        guard let list = value as? [Any], !list.isEmpty else { return nil }
        var messages: [Message] = []
        messages.reserveCapacity(list.count)
        for element in list {
            guard let object = element as? [String: Any], let message = Message(object: object) else { return nil }
            messages.append(message)
        }
        return messages
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
        guard json.contains("\"Page.frameNavigated\"") || json.contains("\"Page.loadEventFired\""),
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

    static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.blockingJSONObject(with: data)) as? [String: Any]
    }

    /// A JavaScript string literal (JSON is a subset of JavaScript).
    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// The reply call: the reply as JSON (`null` for none); a reply that is not JSON becomes the
    /// host's failure envelope, so the page's promise still settles. With `document`, only the
    /// document of that token takes it (a reply evaluated in the main frame after it navigated).
    static func resolveExpression(seq: Int, reply: Any?, document: String? = nil) -> String {
        guard let document else { return "globalThis.\(ChromiumPageHostBridge.resolveName)?.(\(seq), \(replyJSON(reply)));" }
        return "globalThis.\(ChromiumPageHostBridge.resolveName)?.(\(seq), \(replyJSON(reply)), \(jsonString(document)));"
    }

    /// The host's failure envelope, `{ok: false, error: {code, userMessage}}`, as JSON.
    static func failureJSON(code: String, message: String) -> String {
        #"{"ok":false,"error":{"code":"# + jsonString(code) + #","userMessage":"# + jsonString(message) + "}}"
    }

    /// The reply as a page push (``ChromiumPageHostBridge/pushReceiverScript``):
    /// `{"r":seq,"d":doc,"v":reply}`, with the reply's JSON as ``resolveExpression(seq:reply:document:)``
    /// writes it. `doc` is the token of the document that sent the call; any other document's
    /// receiver ignores the reply.
    static func replyPush(seq: Int, doc: String, reply: Any?) -> String {
        #"{"r":\#(seq),"d":\#(jsonString(doc)),"v":\#(replyJSON(reply))}"#
    }

    /// `reply` as JSON: `null` for none, the host's failure envelope for a value that is not JSON.
    private static func replyJSON(_ reply: Any?) -> String {
        guard let reply, !(reply is NSNull) else { return "null" }
        // `JSONSerialization` raises an Objective-C exception (it does not throw) for a value
        // that is not JSON, such as a `Date`: check first, wrapped in an array so a bare string
        // or number counts too.
        let invalid = failureJSON(code: "native.invalid_reply", message: "Invalid reply")
        guard JSONSerialization.isValidJSONObject([reply]) else { return invalid }
        return (try? JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? invalid
    }
}
