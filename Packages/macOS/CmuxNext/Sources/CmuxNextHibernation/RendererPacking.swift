import CoreGraphics
import os

/// Which chat page to build again so a later cmux-page renderer can exit (goal memory-per-chat).
///
/// The fork puts a cmux page in the oldest renderer of its site holding fewer than the cap's pages, or in a
/// new renderer, and keeps it there for its life (`CEFSwitches.processPerSitePageCap`). A burst of opened
/// chats fills the oldest renderer while the hidden ones still wait out `HiddenChatPages.minimumHidden`, so the
/// last chats are born in a second renderer. When the hidden ones go, the oldest has room again, but the
/// visible chat keeps the second renderer alive alone: on a fleet Mac, 180 MB settled for 10 chats (ratio 1.345
/// against goal 1.2). Building that chat's page again puts it in the oldest renderer, and the second exits.
///
/// Pure: the App feeds the live pages (`CEFEngine.rendererPages`) and which of them it may build again.
public enum RendererPacking {
    public struct Page: Equatable, Sendable {
        /// The page's browser id.
        public var browser: Int32
        /// Its renderer's `--renderer-client-id`: later renderers have higher ids.
        public var renderer: Int32
        /// Its origin (`cmux-page://cmux.agent`): the fork shares a renderer only within a site.
        public var site: String
        /// The App may build this page again now (a visible, idle chat of this Mac).
        public var movable: Bool

        public init(browser: Int32, renderer: Int32, site: String, movable: Bool) {
            self.browser = browser
            self.renderer = renderer
            self.site = site
            self.movable = movable
        }
    }

    /// The page to build again, or nil. Only a renderer every page of which may move is emptied (one page left
    /// behind keeps the renderer, so a move would buy nothing), and only when older renderers of that site have
    /// room for all of them. The newest such renderer goes first; its lowest browser id moves first, and the App
    /// asks again after each move.
    public static func nextMove(_ pages: [Page], cap: Int) -> Int32? {
        guard cap > 0 else { return nil }
        let byRenderer = Dictionary(grouping: pages, by: \.renderer)
        for renderer in byRenderer.keys.sorted(by: >) {
            guard let held = byRenderer[renderer], held.allSatisfy(\.movable) else { continue }
            let sites = Set(held.map(\.site))
            guard sites.count == 1, let site = sites.first else { continue }
            let room = byRenderer.reduce(0) { sum, entry in
                guard entry.key < renderer, entry.value.contains(where: { $0.site == site }) else { return sum }
                return sum + max(0, cap - entry.value.count)
            }
            if room >= held.count, let first = held.map(\.browser).min() { return first }
        }
        return nil
    }
}

/// What ``RendererPackingRun`` reads from the App and asks it to do: the App's `AgentPageHibernation` conforms
/// with forwards to its tab store, the engine's live pages and the pane that shows a chat.
@MainActor
package protocol RendererPackingHost: AnyObject {
    /// A chat tab's page (the App's view).
    associatedtype Page: AnyObject
    /// Every tab's page by its stored key; nil while the App has made no agent tab store.
    func hibernationPages() -> [String: Page]?
    /// The clock retries are measured on (tests set it).
    func pageClock() -> ContinuousClock.Instant
    /// A shown, painted, idle Chromium chat of this Mac that a rebuild could move.
    func packingMayMove(_ key: String, _ page: Page) -> Bool
    /// The browser id of the chat's Chromium page.
    func packingBrowser(_ page: Page) -> Int32?
    /// The engine's live pages (`CEFEngine.rendererPages`).
    func packingLivePages() -> [RendererPacking.LivePage]
    /// Builds chat `key`'s page again under its own frame: keeps what acpmux does not hold, takes its picture,
    /// then, only if `stillIdle()` holds after those awaits, lets the page go and shows the tab again. Nil when
    /// rebuilt, else why not.
    func packingRebuild(_ key: String, _ page: Page, stillIdle: @escaping @MainActor () -> Bool) async -> String?
}

extension RendererPacking {
    /// A live Chromium page as the engine lists it.
    package struct LivePage: Equatable, Sendable {
        package var browser: Int32
        package var origin: String
        package var rendererClients: [Int32]
        package var exited: Bool

        package init(browser: Int32, origin: String, rendererClients: [Int32], exited: Bool) {
            self.browser = browser
            self.origin = origin
            self.rendererClients = rendererClients
            self.exited = exited
        }
    }

    /// Seconds since the person's last key, click or scroll anywhere in the session.
    package nonisolated static func secondsSinceInput() -> Double {
        let kinds: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}

/// Builds a visible chat's page again when that lets a later cmux-page renderer exit (``RendererPacking``).
///
/// A burst of opened chats leaves the visible one alone in a second renderer once the hidden ones are released:
/// 180 MB settled on a fleet Mac for 10 chats, nearly all of the per-chat renderer cost (bench 6b4a829c, ratio 1.345
/// against goal 1.2). The cap stays 8 (Leo, 2026-11-21: one renderer crash reloads at most 8 chats); the rebuild
/// only refills older renderers' room.
///
/// The rebuild is the hibernation reshow path on a shown page (the App's ``RendererPackingHost/packingRebuild``):
/// the new page is built off the window and comes back whole once it painted, so the person sees the same frame
/// throughout; the fork places it in the oldest renderer with room, and the old one, empty, exits. Leo,
/// 2026-11-17: "instant > memory": only an idle chat is rebuilt (no turn running, no key, click or scroll for
/// ``inputQuiet`` seconds, before and through the capture), and each tab at most once per ``retryAfter``.
@MainActor
package final class RendererPackingRun<Host: RendererPackingHost> {
    /// After a release, the wait before the planner looks (the released page's renderer drops it at its close).
    package static var settle: Duration { .seconds(2) }
    /// Seconds with no key, click or scroll in the app before a shown chat may be rebuilt.
    package static var inputQuiet: Double { 3 }
    /// Seconds before a tab rebuilt (or tried) is looked at again: a page the fork kept in a later renderer is not
    /// rebuilt in a loop.
    package static var retryAfter: Double { 600 }

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    private weak var host: Host?
    private let timer: any WorkspaceHibernationDeadline
    private var tried: [String: ContinuousClock.Instant] = [:]
    package private(set) var rebuilding = false
    /// Rebuilds done this run (`debug` readers and tests).
    package private(set) var rebuilt = 0
    /// The fork's pages per renderer (`CEFEngine.cmuxPagesPerRenderer`).
    package var cap: Int
    /// Seconds since the person's last key, click or scroll (tests set it).
    package var secondsSinceInput: () -> Double = RendererPacking.secondsSinceInput

    package init(host: Host, cap: Int, timer: any WorkspaceHibernationDeadline) {
        self.host = host
        self.cap = cap
        self.timer = timer
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050); nothing to clean up.
    nonisolated deinit {}

    /// A page was released (room may have come in an older renderer): look again after ``settle``. A rebuild in
    /// flight looks again when it ends.
    package func schedule(after delay: Duration = settle) {
        guard !rebuilding else { return }
        timer.schedule(after: delay) { @MainActor [weak self] in await self?.pack() }
    }

    /// One planner step: rebuilds at most one page, then looks again.
    package func pack() async {
        guard !rebuilding, let host, let pages = host.hibernationPages() else { return }
        let now = host.pageClock()
        tried = tried.filter { now - $0.value < .seconds(Self.retryAfter) }
        let quiet = secondsSinceInput() >= Self.inputQuiet
        var movable: [Int32: (key: String, page: Host.Page)] = [:]
        var waitsForQuiet = false
        for (key, page) in pages where tried[key] == nil && host.packingMayMove(key, page) {
            guard let browser = host.packingBrowser(page) else { continue }
            if quiet { movable[browser] = (key, page) } else { waitsForQuiet = true }
        }
        let live = host.packingLivePages().compactMap { page -> RendererPacking.Page? in
            guard page.origin.hasPrefix("cmux-page:"), !page.exited, let renderer = page.rendererClients.first else { return nil }
            return RendererPacking.Page(browser: page.browser, renderer: renderer, site: page.origin,
                                        movable: page.rendererClients.count == 1 && movable[page.browser] != nil)
        }
        guard let browser = RendererPacking.nextMove(live, cap: cap), let (key, page) = movable[browser] else {
            if waitsForQuiet { schedule(after: .seconds(Self.inputQuiet)) }
            return
        }
        rebuilding = true
        tried[key] = now
        let started = ContinuousClock.now
        // The person may come back while the page answers: nothing they do in that time is lost.
        let failure = await host.packingRebuild(key, page) { [weak self, weak host] in
            guard let self, let host else { return false }
            return secondsSinceInput() > (ContinuousClock.now - started) / .seconds(1) && host.packingMayMove(key, page)
        }
        rebuilding = false
        if let failure {
            logger.info("agent page \(key, privacy: .public) not rebuilt for its renderer: \(failure, privacy: .public)")
        } else {
            rebuilt += 1
            logger.notice("rebuilt agent page \(key, privacy: .public) so a later renderer can exit")
        }
        schedule()
    }
}
