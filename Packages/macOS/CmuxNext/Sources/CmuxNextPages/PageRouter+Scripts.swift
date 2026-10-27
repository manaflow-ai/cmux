public import CmuxNextSettings

/// The scripts that carry router envelopes into the page: the host half of webviews pageClient.ts
/// (`__cmuxPageReceive`, `__cmuxPageReceiveMany`).
extension PageRouter {
    /// The script that delivers `envelope` to the page.
    /// One buffer: the envelope's JSON is appended in place, never built and copied.
    public nonisolated static func receiveScript(_ envelope: JSONValue) -> String {
        var script = "window.__cmuxPageReceive && window.__cmuxPageReceive("
        envelope.appendCompactText(to: &script)
        script += ");"
        return script
    }

    /// The script that delivers `envelopes` to the page in order, as one evaluate: the page's
    /// `window.__cmuxPageReceiveMany` (webviews pageClient.ts), or for a page without it each
    /// envelope through `__cmuxPageReceive`, one that throws not stopping the rest. One envelope
    /// is ``receiveScript(_:)``; none is an empty script.
    public nonisolated static func receiveManyScript(_ envelopes: [JSONValue]) -> String {
        guard envelopes.count > 1 else { return envelopes.first.map { receiveScript($0) } ?? "" }
        var script = receiveManyPrefix + "["
        appendArrayItems(envelopes, to: &script)
        script += "]);"
        return script
    }

    /// The envelopes as one JSON array: the page push channel's form of ``receiveManyScript(_:)``
    /// (``PageHostPushing``). The page script parses it and hands it to the page's receiver, which
    /// takes it as `__cmuxPageReceiveMany` does; no script is compiled for it.
    public nonisolated static func receiveManyData(_ envelopes: [JSONValue]) -> String {
        var text = "["
        appendArrayItems(envelopes, to: &text)
        text += "]"
        return text
    }

    /// ``receiveManyScript(_:)`` of envelopes already in their data form (``receiveManyData(_:)``).
    public nonisolated static func receiveManyScript(data json: String) -> String {
        receiveManyPrefix + json + ");"
    }

    private nonisolated static let receiveManyPrefix = "(function(m){var many=window.__cmuxPageReceiveMany;if(many){many(m);return}"
        + "var one=window.__cmuxPageReceive;if(!one)return;"
        + "for(var i=0;i<m.length;i++){try{one(m[i])}catch(e){console.error(e)}}})("

    private nonisolated static func appendArrayItems(_ envelopes: [JSONValue], to text: inout String) {
        for (index, envelope) in envelopes.enumerated() {
            if index > 0 { text += "," }
            envelope.appendCompactText(to: &text)
        }
    }
}
