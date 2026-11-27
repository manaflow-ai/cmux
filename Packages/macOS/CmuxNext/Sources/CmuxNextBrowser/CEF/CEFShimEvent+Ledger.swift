import CmuxNextCompat

extension CEFShimEvent {
    /// The wake ledger's reason for this event (bench and Debug builds record every event the main thread takes,
    /// `cefEventCallback`): a DevTools message by its method (`devTools Page.lifecycleEvent`, or `devTools reply`),
    /// every other event by its case. A renderer's DevTools session messages reach the main thread through
    /// Chromium's I/O thread (cmux20-bench, 2026-11-25: 0.9/s at idle, `blink.mojom.DevToolsSessionHost`); this
    /// names them.
    var ledgerReason: String {
        switch self {
        case .devToolsMessage(_, let json):
            let method = DevToolsMessageHead(json: json).method
            guard let method else { return "devTools reply" }
            guard method == "Runtime.bindingCalled" else { return "devTools " + method }
            // The binding, and a page host call's op (`{t: "call", op}`, escaped in the string payload).
            var reason = "devTools " + method
            if let name = Self.value(after: #""name":""#, in: json) { reason += " " + name }
            if let op = Self.value(after: #"\"op\":\""#, in: json, escaped: true) { reason += " " + op }
            return reason
        case .unknown(let kind):
            return "unknown \(kind)"
        default:
            return Mirror(reflecting: self).children.first?.label ?? String(describing: self)
        }
    }

    /// The text after the first `key` in `json`, up to its closing quote (`\"` when `escaped`); nil when absent or
    /// longer than a name (64 bytes).
    private static func value(after key: String, in json: String, escaped: Bool = false) -> String? {
        guard let start = json.range(of: key)?.upperBound else { return nil }
        let rest = json[start...].prefix(65)
        guard let end = rest.range(of: escaped ? #"\""# : #"""#)?.lowerBound else { return nil }
        let value = rest[..<end]
        return value.isEmpty ? nil : String(value)
    }
}
