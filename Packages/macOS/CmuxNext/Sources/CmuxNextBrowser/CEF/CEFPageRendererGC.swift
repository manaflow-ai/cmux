import CmuxNextWakeups
import Foundation

/// Collects what closed cmux pages leave behind in the renderer they shared.
///
/// Every agent chat is `cmux-page://cmux.agent/`, and the fork gives such a scheme one renderer per site
/// (`CEFSwitches.processPerSitePageSchemes`), so a closed chat's JavaScript heap becomes garbage in a renderer
/// that lives on and that idle V8 does not collect: on cmux13s (DEV 5e5df62, 10 workspaces, a chat opened
/// and closed every ~2.5 s) the chat renderer grew 420 -> 881 MB over 300 closes while its live heap after a
/// forced collection stayed at 55-91 MB and its pages and documents stayed at 3; the heap before collection
/// was 546 MB. Chrome never meets this: a closed tab's renderer exits. One moderate memory-pressure notice
/// (V8's memory-reducing incremental collection, Blink's cache trims) took the renderer back to 388 MB.
///
/// So every cmux page close (a chat closed, a hidden chat released) asks for one notice per renderer that
/// still hosts cmux pages, ``delay`` after the first close of a burst: a renderer of chats that stay open
/// gets it too, at most once per ``delay``, and a close every 2 s still gets one every ``delay``. The notice
/// goes through one live page per renderer, in that page's DevTools call order (`postDevTools`).
@MainActor
final class CEFPageRendererGC {
    static let delay: Duration = .seconds(10)
    static let method = "Memory.simulatePressureNotification"
    static let level = "moderate"

    /// A live page, as the collection picks its targets.
    struct Page: Equatable {
        var browser: Int32
        var isCmuxPage: Bool
        var rendererClients: [Int32]
    }

    private let timer = DemandTimer(owner: "CEFPageRendererGC")
    private let pages: @MainActor () -> [Page]
    private let post: @MainActor (Int32) -> Void

    init(pages: @escaping @MainActor () -> [Page], post: @escaping @MainActor (Int32) -> Void) {
        self.pages = pages
        self.post = post
    }

    /// A cmux page closed: its renderer's garbage is collected within ``delay``.
    func pageClosed() {
        timer.scheduleIfIdle(after: Self.delay) { @MainActor [weak self] in self?.collect() }
    }

    func cancel() { timer.cancel() }

    private func collect() {
        for browser in Self.targets(pages()) { post(browser) }
    }

    /// One cmux page per renderer that hosts cmux pages (the lowest browser id of its main-frame renderer), in
    /// browser order. A page whose renderer is unknown is skipped: a page still loading has nothing to collect.
    static func targets(_ pages: [Page]) -> [Int32] {
        var byRenderer: [Int32: Int32] = [:]
        for page in pages where page.isCmuxPage {
            guard let renderer = page.rendererClients.first else { continue }
            byRenderer[renderer] = min(byRenderer[renderer] ?? page.browser, page.browser)
        }
        return byRenderer.values.sorted()
    }

    static func isCmuxPage(_ url: URL?) -> Bool { url?.scheme == "cmux-page" }
}
