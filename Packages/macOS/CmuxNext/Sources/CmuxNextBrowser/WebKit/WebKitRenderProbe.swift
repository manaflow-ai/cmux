public import WebKit

/// When a web view has rendered a frame: two animation frames, in a world the
/// page's scripts do not see. A view WebKit stopped rendering while hidden
/// draws an empty page until then.
@MainActor
public enum WebKitRenderProbe {
    /// Runs `body` once `webView` has rendered a frame, or at once when the
    /// script cannot run (a closed page).
    public static func afterNextRender(_ webView: WKWebView, _ body: @escaping () -> Void) {
        last &+= 1
        let id = last
        waiting[id] = body
        // The handler (on the main actor) carries only the id.
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: world) { _ in
            waiting.removeValue(forKey: id)?()
        }
    }

    private static var waiting: [Int: () -> Void] = [:]
    private static var last = 0

    private static let script = "await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)))"
    private static let world = WKContentWorld.world(name: "cmux.render")
}
