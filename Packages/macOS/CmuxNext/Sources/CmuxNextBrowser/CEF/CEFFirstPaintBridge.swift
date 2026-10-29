import Foundation
import CmuxNextWakeups

/// When a Chromium document first paints content, through the DevTools
/// protocol's page lifecycle events (`CEFAgentRelay.deliver` hands every raw
/// message here first).
///
/// The page base stands in for a committed document only until that document
/// paints something of its own (`CEFTab+LoadingBackground`). Chromium has no
/// shim event for that: `OnLoadEnd` is the end of the *load*, which on a slow
/// page is seconds after the text is on screen. Waiting for it would leave the
/// theme color as the canvas under a page that is already being read -- black
/// UA text over a dark theme color -- and then swap to white at load end, which
/// is the flash this stands in for, moved later.
///
/// So the boundary is `firstContentfulPaint`, Blink's own "the user can see
/// page content now". Lifecycle events are a handful per navigation, and raw
/// protocol events already reach every attached tab (`CEFMediaBridge.attach`
/// turns on `mediaListens`, which keeps the shim's event watch on).
/// `CEFTab+Events` still settles at load end as the backstop, for a document
/// that paints nothing at all (an empty body, a download) and for the tabs
/// this bridge never attaches to.
final class CEFFirstPaintBridge {
    /// Blink's lifecycle event name for the first paint of page content.
    /// Nonisolated, like the matcher that reads it: the module's default
    /// isolation is MainActor, and `isFirstContentfulPaint` is pure.
    nonisolated static let firstContentfulPaint = "firstContentfulPaint"

    /// Weak: the tab owns the relay that owns this bridge.
    private weak var tab: CEFTab?
    /// The main frame's DevTools id, so a subframe painting first does not
    /// hand the page area over. Stable across this tab's navigations, so it is
    /// resolved once. Nil until it is: every frame counts until then, which is
    /// the old load-end behavior at worst.
    private var mainFrame: String?

    init(tab: CEFTab) { self.tab = tab }

    /// The tab's browser exists (`CEFAgentRelay.browserAttached`).
    func attach(_ browser: Int32) {
        guard let tab else { return }
        let runtime = tab.runtime
        Task { [weak self] in
            do {
                // `Page.enable` first: `CEFMediaBridge.attach` sends its own on
                // the same turn and neither bridge may depend on that order.
                _ = try await runtime.devTools(browser, method: "Page.enable")
                _ = try await runtime.devTools(browser, method: "Page.setLifecycleEventsEnabled", params: ["enabled": true])
                let tree = try await runtime.devTools(browser, method: "Page.getFrameTree")
                guard let self, self.tab?.browserID == browser else { return }
                self.mainFrame = CEFDevToolsResult.mainFrameID(tree)
            } catch {
                // The page then settles at load end, as it did before.
                runtime.logger.info("first paint: lifecycle events failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A `Page.lifecycleEvent` of the main frame's first contentful paint: the
    /// document owns the page area from now on. Always false, so this only
    /// reads the stream and never takes a message off it: an agent relaying
    /// raw protocol messages still sees every lifecycle event.
    func handle(_ json: String) -> Bool {
        if Self.isFirstContentfulPaint(json, mainFrame: mainFrame) { painted() }
        return false
    }

    /// The main frame's document painted content (a lifecycle event, or from fork API 29 the
    /// first paint channel, `BrowserFirstPaintScript`).
    func painted() {
        #if DEBUG || CMUX_BENCH_HOOKS
        ChatOpenTrace.shared.mark(.firstContentfulPaint, chromiumPane: tab?.host.key.pane.rawValue)
        if let tab { tab.runtime.benchMarks.firstPaint(tab.id.rawValue) }
        #endif
        tab?.documentDidSettle()
    }

    /// Whether `json` is the first contentful paint of `mainFrame`. A
    /// subframe's paint is not the page's, so it does not count -- except
    /// before the main frame is known, when every frame does: that is the
    /// load-end behavior at worst, never a missed hand-over.
    nonisolated static func isFirstContentfulPaint(_ json: String, mainFrame: String?) -> Bool {
        guard json.contains("\"Page.lifecycleEvent\""), json.contains("\"\(firstContentfulPaint)\""),
              let data = json.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "Page.lifecycleEvent",
              let params = message["params"] as? [String: Any],
              params["name"] as? String == firstContentfulPaint
        else { return false }
        guard let mainFrame else { return true }
        return params["frameId"] as? String == mainFrame
    }
}
