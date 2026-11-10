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
/// link is one end of a socket pair; the test reads the frames from the other end.
@MainActor @Suite(.serialized)
struct BrowserHostPopupReadTests {
    private static let workspaceKey = WorkspaceKey(rawValue: "popup-read-ws")
    private static let openerSurface = SurfaceID(rawValue: 2)
    private static let childSurface = SurfaceID(rawValue: 3)

    /// One workspace, one pane: a terminal and the opener's page; with `child`, also the page the opener opened.
    private static func tree(child: Bool) -> DaemonTree {
        var tabs = [
            TabSnapshot(surface: SurfaceID(rawValue: 1), title: "zsh"),
            TabSnapshot(surface: openerSurface, kind: .browser, url: "http://127.0.0.1:9/opener",
                        browserRenderer: "frontend", browserEngine: "webkit"),
        ]
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

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<80 { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(2)))
    func aPopupPlacedInTheTurnOfItsStoreChangeIsAnnouncedThenReported() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(child: false))
        let host = try #require(services.browserHost, "fixture: the app services started no browser host")
        // The feed lists the opener, and the provider's own connect attempt ended (no daemon connection: no credentials).
        for _ in 0..<4 { await Self.drainMain() }
        let opener = try #require(store.tab(surface: Self.openerSurface), "fixture: the store has no opener tab")
        try #require(host.tabs.isDrivable(opener.id), "fixture: the host does not list the opener's tab")

        // The provider's link: one end of a socket pair. A new link announces every listed tab.
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "fixture: socketpair failed (errno \(errno))")
        let reader = FrameReader(fd: fds[1])
        host.provider.connection = ProviderConnection(fd: fds[0])
        host.provider.refreshTabs()

        // ONE main-actor turn: the store gets the child, and the opener's placement ends.
        store.apply(snapshot: Self.tree(child: true))
        let child = try #require(store.tab(surface: Self.childSurface), "fixture: the store has no child tab")
        #expect(host.tabs.isDrivable(child.id), "the store holds the child's page in this turn, and the host says it is not drivable")
        let placed = try #require(services.cache.pageRequests.openers.onChildPlaced, "fixture: the host set no placement callback")
        placed(Self.childSurface, Self.openerSurface)

        // Every frame up to the popup event (or until no frame comes for 3 s).
        let events = await reader.events(through: "tab.created")
        let names = events.map(\.name)
        try #require(child.id != opener.id, "fixture: the two tabs have one id")
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

        host.provider.dropConnection(reason: "the test ended")
        await reader.close()
    }
}

/// The host's end of the provider's link. Its reads block on the actor's executor (off the main actor, where the
/// provider runs), each bounded by the socket's receive timeout, so a missing frame fails the test, never hangs it.
private actor FrameReader {
    private let fd: Int32
    private var decoder = ProviderFrameDecoder()

    init(fd: Int32) {
        self.fd = fd
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The events read up to the first one named `last` (included), or up to a read that gave nothing in 3 s; each
    /// with its `targetId` and `openerTargetId`.
    func events(through last: String) -> [(name: String, target: String?, opener: String?)] {
        var seen: [(name: String, target: String?, opener: String?)] = []
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            while let frame = try? decoder.next() {
                guard case .event(let name, let payload) = frame else { continue }
                var target: String?, opener: String?
                if case .object(let fields) = payload {
                    if case .string(let id)? = fields["targetId"] { target = id }
                    if case .string(let id)? = fields["openerTargetId"] { opener = id }
                }
                seen.append((name, target, opener))
                if name == last { return seen }
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
