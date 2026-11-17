import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextBrowserHost
import CmuxNextCompat
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// Follow-up of #40544 (CMD-T BUDGET, 2026-11-10): the browser host's tab list comes from one observation per
/// workspace, so it follows the store one main-actor turn later. Two reads of the host run in the turn of a store
/// change and must not depend on that turn:
///
/// - The popup event. A page opens a tab; when its placement ends (`BrowserTabOpeners.onChildPlaced`), the host gets
///   `tab.announced` for the child and then `tab.created` with its opener, so a session's `waitForEvent("popup")`
///   fires. With the list one turn behind, a placement that ends in the store's turn found no announced child and
///   sent nothing: the event was lost with no error.
/// - "Is this tab drivable" for one tab id (the relay, the agent mark): the tab's own facts, now.
///
/// The test forces the order: the store gets the child and the placement ends in ONE main-actor turn (what
/// `BrowserTabService.settled` gives when it does not suspend after the store applied the event). The provider's
/// link is one end of a socket pair; the test reads the frames from the other end. It waits on facts only (the
/// list holds the opener, the provider's pass announced the child) and ends each read with a frame of its own.
@MainActor @Suite(.serialized)
struct BrowserHostPopupReadTests {
    private static let workspaceKey = WorkspaceKey(rawValue: "popup-read-ws")
    private static let openerSurface = SurfaceID(rawValue: 2)
    private static let childSurface = SurfaceID(rawValue: 3)

    /// The frame the test sends itself after the provider's pass: the reader stops there, so what it read is every
    /// frame of that pass (the link's writes leave in `send` order).
    private static let endEvent = "test.popup-read.end"

    /// One workspace, one pane: a terminal, with `opener` the opener's page and with `child` the page it opened.
    private static func tree(opener: Bool = true, child: Bool) -> DaemonTree {
        var tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "zsh")]
        if opener {
            tabs.append(TabSnapshot(surface: openerSurface, kind: .browser, url: "http://127.0.0.1:9/opener",
                                    browserRenderer: "frontend", browserEngine: "webkit"))
        }
        if child {
            tabs.append(TabSnapshot(surface: childSurface, kind: .browser, url: "http://127.0.0.1:9/child",
                                    browserRenderer: "frontend", browserEngine: "webkit"))
        }
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        let workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: workspaceKey, name: "workspace", screens: [screen])
        var tree = DaemonTree(registryID: "s-local", workspaces: [workspace])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: workspaceKey, index: 0)])
        return tree
    }

    /// Lets the main actor run what is queued until `fact` holds: a wait on the fact itself, never on a count of
    /// turns. The limit only ends a run whose fact never comes (false then), so a loaded host fails no run.
    private static func until(_ fact: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), limit = clock.now.advanced(by: .seconds(60))
        while !fact() {
            guard clock.now < limit else { return false }
            await Task.yield()
        }
        return true
    }

    /// The app's services with the opener's page in the host's list, and the provider's link: one end of a socket
    /// pair, whose other end the test reads.
    @MainActor private struct Linked {
        let services: AppServices
        let host: AppBrowserHost
        let reader: FrameReader
        let opener: TabModel
        var store: DaemonStore { services.daemon.store }

        /// Every event the provider sent up to now: waits for `passed` (a fact of the provider's pass), sends the
        /// end frame behind that pass's frames, and reads up to it.
        func events(after passed: () -> Bool) async -> [FrameReader.Event] {
            let came = await BrowserHostPopupReadTests.until(passed)
            #expect(came, "the provider's pass did not come; announced: \(host.provider.announced.keys.sorted())")
            host.provider.send(.event(name: BrowserHostPopupReadTests.endEvent, payload: .object([:])))
            return await reader.events(through: BrowserHostPopupReadTests.endEvent)
        }

        func end() async {
            host.provider.dropConnection(reason: "the test ended")
            await reader.close()
        }
    }

    private static func linked() async throws -> Linked {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        let host = try #require(services.browserHost, "fixture: the app services started no browser host")
        let attempts = host.provider.generation
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(child: false))
        let opener = try #require(store.tab(surface: Self.openerSurface), "fixture: the store has no opener tab")
        // Two facts, each waited for: the provider took the store's new connection state (a new connect attempt, which
        // ends idle: no daemon connection, so no credentials) and replaces no link after this; and the host's list,
        // which follows the store, holds the opener. The list itself is read: `isDrivable` is a store read.
        let ready = await Self.until {
            host.provider.generation > attempts && host.provider.status == .idle
                && host.tabs.providerTabs.contains { $0.targetID == opener.id }
        }
        try #require(ready, """
            fixture: the host's list did not get the opener's tab, or the provider did not end its connect attempt; \
            list: \(host.tabs.providerTabs.map(\.targetID)), status: \(host.provider.status)
            """)

        // The provider's link: one end of a socket pair. A new link announces every listed tab.
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "fixture: socketpair failed (errno \(errno))")
        let reader = FrameReader(fd: fds[1])
        host.provider.connection = ProviderConnection(fd: fds[0])
        host.provider.refreshTabs()
        try #require(host.provider.announced[opener.id] != nil, "fixture: the new link did not announce the opener")
        return Linked(services: services, host: host, reader: reader, opener: opener)
    }

    @Test(.timeLimit(.minutes(3)))
    func aPopupPlacedInTheTurnOfItsStoreChangeIsAnnouncedThenReported() async throws {
        let linked = try await Self.linked()
        let store = linked.store, host = linked.host, opener = linked.opener

        // ONE main-actor turn: the store gets the child, and the opener's placement ends.
        store.apply(snapshot: Self.tree(child: true))
        let child = try #require(store.tab(surface: Self.childSurface), "fixture: the store has no child tab")
        try #require(child.id != opener.id, "fixture: the two tabs have one id")
        #expect(host.tabs.isDrivable(child.id), "the store holds the child's page in this turn, and the host says it is not drivable")
        let placed = try #require(linked.services.cache.pageRequests.openers.onChildPlaced, "fixture: the host set no placement callback")
        placed(Self.childSurface, Self.openerSurface)

        // Every frame of the pass that announces the child.
        let events = await linked.events { host.provider.announced[child.id] != nil }
        let names = events.map(\.name)
        let announcedAt = events.firstIndex { $0.name == "tab.announced" && $0.target == child.id }
        let createdAt = events.firstIndex { $0.name == "tab.created" && $0.target == child.id && $0.opener == opener.id }
        #expect(announcedAt != nil, "the host did not get tab.announced for the child; events: \(names)")
        #expect(createdAt != nil, "the popup event tab.created (child, opener) was lost; events: \(names)")
        if let announcedAt, let createdAt {
            #expect(announcedAt < createdAt, "tab.created came before the child's tab.announced; events: \(names)")
        }

        // The other direction, also in ONE turn: the store drops the child; it is not drivable in that turn.
        store.apply(snapshot: Self.tree(child: false))
        #expect(!host.tabs.isDrivable(child.id), "the store dropped the child's page in this turn, and the host says it is drivable")
        await linked.end()
    }

    /// The opener closes before the list announced its popup (the page called `window.open` and then `window.close`,
    /// or an agent closed it): the list's next pass announces the child and drops the opener together. The host
    /// still gets the popup event, as it did while the list was exact (the report came with both tabs announced):
    /// a session that owns the opener owns its popup (`provider_engine.rs`), and CDP's `Target.targetCreated` carries
    /// `openerId` whether the opener still lives or not. The event goes before the opener's `tab.gone`.
    @Test(.timeLimit(.minutes(3)))
    func aPopupWhoseOpenerLeavesBeforeItsAnnounceIsStillReported() async throws {
        let linked = try await Self.linked()
        let store = linked.store, host = linked.host, opener = linked.opener

        // ONE main-actor turn: the store gets the child, the opener's placement ends, and the store drops the opener.
        store.apply(snapshot: Self.tree(child: true))
        let child = try #require(store.tab(surface: Self.childSurface), "fixture: the store has no child tab")
        try #require(child.id != opener.id, "fixture: the two tabs have one id")
        let placed = try #require(linked.services.cache.pageRequests.openers.onChildPlaced, "fixture: the host set no placement callback")
        placed(Self.childSurface, Self.openerSurface)
        store.apply(snapshot: Self.tree(opener: false, child: true))
        try #require(store.tab(surface: Self.openerSurface) == nil, "fixture: the store still holds the opener")

        // Every frame of the pass that announces the child and drops the opener.
        let events = await linked.events { host.provider.announced[child.id] != nil && host.provider.announced[opener.id] == nil }
        let names = events.map(\.name)
        let announcedAt = events.firstIndex { $0.name == "tab.announced" && $0.target == child.id }
        let createdAt = events.firstIndex { $0.name == "tab.created" && $0.target == child.id && $0.opener == opener.id }
        let goneAt = events.firstIndex { $0.name == "tab.gone" && $0.target == opener.id }
        #expect(announcedAt != nil, "the host did not get tab.announced for the child; events: \(names)")
        #expect(goneAt != nil, "the host did not get tab.gone for the opener; events: \(names)")
        #expect(createdAt != nil, "the popup event tab.created (child, opener) was lost with its opener; events: \(names)")
        if let announcedAt, let createdAt, let goneAt {
            #expect(announcedAt < createdAt, "tab.created came before the child's tab.announced; events: \(names)")
            #expect(createdAt < goneAt, "tab.created came after its opener's tab.gone; events: \(names)")
        }
        await linked.end()
    }
}

/// The host's end of the provider's link. Its reads block on the actor's executor (off the main actor, where the
/// provider runs). The test ends each read with a frame of its own, so no read waits for time to pass; the socket's
/// receive timeout only ends a run whose end frame never comes, so that run fails and does not hang.
private actor FrameReader {
    /// One event frame, with its `targetId` and `openerTargetId`.
    struct Event: Sendable {
        var name: String
        var target: String?
        var opener: String?
    }

    private let fd: Int32
    private var decoder = ProviderFrameDecoder()

    init(fd: Int32) {
        self.fd = fd
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The events read up to the first one named `last` (not included), or up to the link's end.
    func events(through last: String) -> [Event] {
        var seen: [Event] = []
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            while let frame = try? decoder.next() {
                guard case .event(let name, let payload) = frame else { continue }
                if name == last { return seen }
                var event = Event(name: name)
                if case .object(let fields) = payload {
                    if case .string(let id)? = fields["targetId"] { event.target = id }
                    if case .string(let id)? = fields["openerTargetId"] { event.opener = id }
                }
                seen.append(event)
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return seen }
            buffer.withUnsafeBytes { decoder.push(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
    }

    func close() {
        Darwin.close(fd)
    }
}
