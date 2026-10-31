import Foundation
import WebKit

/// What a web pane's bridge reaches: the app supervisor, which decides every
/// call (``AppsClient/webCall(app:op:params:)``), and the app's log ring.
/// Tests supply their own.
@MainActor
protocol AppWebPaneCalls: AnyObject {
    func webCall(app: String, op: String, params: AppJSON) async throws(AppsClientError) -> AppJSON
    func webLog(app: String, level: String, message: String)
}

extension AppsClient: AppWebPaneCalls {}

/// The page's `cmux` object and the one message handler behind it
/// (custom-panes-DESIGN.md section 3). `cmux.call(op, params)` resolves to the
/// supervisor's ok body or rejects with an `Error` carrying its `code`; the
/// console, uncaught errors and unhandled rejections go to the app's log.
///
/// The handler answers only the main frame at the pane's own origin; a message
/// from anywhere else gets `bridge.origin` and reaches nothing.
@MainActor
final class AppWebPaneBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxApp"
    /// Console lines kept per page load; the rest are dropped with one note.
    static let logLinesPerLoad = 200
    /// Console lines kept over the pane's life, so a page that reloads itself in a loop
    /// cannot flood the app's log either.
    static let logLinesPerPane = 2_000

    let pane: AppWebPane
    /// A replacement with no active web implementation revokes the old document immediately.
    var enabled = true
    weak var calls: (any AppWebPaneCalls)?
    private(set) var loggedThisLoad = 0
    private(set) var loggedThisPane = 0

    init(pane: AppWebPane, calls: any AppWebPaneCalls) {
        self.pane = pane
        self.calls = calls
    }

    /// A new document committed: its console gets a fresh allowance.
    func pageCommitted() { loggedThisLoad = 0 }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard enabled, message.frameInfo.isMainFrame, pane.isOwn(message.frameInfo.request.url) else {
            return (Self.refusal("bridge.origin", "only the pane's own page can call cmux"), nil)
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            return (Self.refusal("bridge.invalid", "not a cmux bridge message"), nil)
        }
        switch kind {
        case "call":
            return (await call(body), nil)
        case "log":
            log(level: body["level"] as? String ?? "info", message: body["message"] as? String ?? "")
            return (nil, nil)
        default:
            return (Self.refusal("bridge.invalid", "not a cmux bridge message"), nil)
        }
    }

    private func call(_ body: [String: Any]) async -> [String: Any] {
        guard let op = body["op"] as? String, !op.isEmpty else {
            return Self.refusal("bridge.invalid", "cmux.call needs an operation name")
        }
        guard let params = try? AppJSON(foundation: body["params"] ?? [String: Any]()), case .object = params else {
            return Self.refusal("bridge.invalid", "cmux.call params must be a JSON object")
        }
        guard let calls else { return Self.refusal("operation.failed", "the pane is closed") }
        do throws(AppsClientError) {
            let value = try await calls.webCall(app: pane.appID, op: op, params: params)
            return ["ok": true, "value": value.foundation]
        } catch {
            switch error {
            case .refused(let refusal): return Self.refusal(refusal.code ?? "operation.failed", refusal.message)
            case .unavailable, .unknownApp: return Self.refusal("operation.failed", error.description)
            }
        }
    }

    /// One more than the daemon keeps of a line (`MAX_LOG_CHARS`, Unicode scalars), so it still
    /// sees and marks a cut. Counted in scalars: one grapheme can carry any number of them.
    static let logLineCharacters = 2_001

    private func log(level: String, message: String) {
        guard loggedThisLoad <= Self.logLinesPerLoad, loggedThisPane <= Self.logLinesPerPane else { return }
        loggedThisLoad += 1
        loggedThisPane += 1
        if loggedThisPane > Self.logLinesPerPane {
            calls?.webLog(app: pane.appID, level: "warn", message: "more console lines from this pane were dropped")
            return
        }
        if loggedThisLoad > Self.logLinesPerLoad {
            calls?.webLog(app: pane.appID, level: "warn", message: "more console lines this load were dropped")
            return
        }
        calls?.webLog(app: pane.appID, level: level, message: String(String.UnicodeScalarView(message.unicodeScalars.prefix(Self.logLineCharacters))))
    }

    static func refusal(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "code": code, "message": message]
    }

    /// No peer connections: ICE talks to any STUN or TURN host, which neither the content policy
    /// nor the egress gate sees. ``AppWebPaneView`` turns WebRTC off in the preferences; this
    /// removes the constructors as well, in every frame (a same-origin `about:blank` child frame
    /// has its own copies), before the frame's first script.
    static let noPeerConnections = WKUserScript(source: """
        for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel",
                            "RTCSessionDescription", "RTCIceCandidate"]) {
          try { delete window[name]; } catch {}
          try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch {}
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    /// The page's `cmux` object, injected before any page script runs.
    static func script(appID: String) -> WKUserScript {
        let app = (try? String(data: JSONSerialization.data(withJSONObject: [appID]), encoding: .utf8)) ?? "[\"\"]"
        let source = """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
          if (!handler) return;
          const post = handler.postMessage.bind(handler);
          const text = (v) => {
            if (typeof v === "string") return v;
            if (v instanceof Error) return v.stack || String(v);
            try { return JSON.stringify(v); } catch { return String(v); }
          };
          const log = (level, args) => { try { post({ kind: "log", level, message: args.map(text).join(" ") }); } catch {} };
          for (const level of ["error", "warn", "info", "debug", "log"]) {
            const original = console[level].bind(console);
            console[level] = (...args) => { log(level === "log" ? "info" : level, args); original(...args); };
          }
          window.addEventListener("error", (e) => log("error", [`${e.message} (${e.filename}:${e.lineno})`]));
          window.addEventListener("unhandledrejection", (e) => log("error", ["Unhandled rejection:", e.reason]));
          const call = async (op, params) => {
            const reply = await post({ kind: "call", op: String(op), params: params === undefined ? {} : params });
            if (reply && reply.ok) return reply.value;
            const error = new Error((reply && reply.message) || "cmux call failed");
            error.code = (reply && reply.code) || "operation.failed";
            throw error;
          };
          Object.defineProperty(window, "cmux", { value: Object.freeze({ app: \(app)[0], call }), enumerable: true });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
