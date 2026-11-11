import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextBrowserHost
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// TAB SWITCH TAIL 2 (2026-11-10): a switch between two page tabs of a pane hides one tab and shows one tab. The
/// browser host must hear of those two tabs (`tab.announced` with the new `visible`), and the work for it must not
/// grow with the session. Before, each of the two changes made the provider start a new pass over its whole list in
/// the switch's turn: every browser tab of the session read again, the extension access of every Chromium page asked
/// again, and every tab compared again (2 passes; at the person's session 516 pages and 258 Chromium pages each).
///
/// The test makes the switch as the pane does (`TabContentCache.withdraw` of the leaving tab, then `present` of the
/// incoming tab, in one main-actor turn) on a session of the size it is given, and counts what the provider did in
/// that turn: the passes it started (`BrowserHostProvider.observation`) and the tabs whose extension access it asked.
/// The provider's link is one end of a socket pair; the test reads the frames from the other end.
@MainActor @Suite(.serialized)
struct BrowserHostTabSwitchReadTests {
    /// The frame the test sends itself after a step: the reader stops there, so what it read is every frame of the step.
    private static let endEvent = "test.tab-switch-read.end"

    /// The provider's access source, counted: forwards each ask to the app's source.
    @MainActor private final class CountedAccess: ProviderAccessSource {
        private let source: any ProviderAccessSource
        private(set) var asked: [String] = []
        init(_ source: any ProviderAccessSource) { self.source = source }
        func access(forTab targetID: String) -> ProviderTabAccess {
            asked.append(targetID)
            return source.access(forTab: targetID)
        }
    }

    /// Lets the main actor run what is queued until `fact` holds: a wait on the fact itself. The limit only ends a
    /// run whose fact never comes (false then).
    private static func until(_ fact: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), limit = clock.now.advanced(by: .seconds(120))
        while !fact() {
            guard clock.now < limit else { return false }
            await Task.yield()
        }
        return true
    }

    @Test(.timeLimit(.minutes(5)), arguments: SessionFixtureSize.arms)
    func aTabSwitchReadsItsTwoTabsAtAnySessionSize(_ size: SessionFixtureSize) async throws {
        try #require(size.mixFaults.isEmpty, "fixture: the \(size.rawValue) mix is wrong: \(size.mixFaults)")
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        let host = try #require(services.browserHost, "fixture: the app services started no browser host")
        let provider = host.provider
        let attempts = provider.generation
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: LargeSessionWindowFixture.tree(size))

        // Two facts, each waited for: the provider ended the connect attempt of the store's new connection state
        // (idle: no daemon connection, so no credentials; it replaces no link after this), and its own pass holds
        // every page of the session (the host's list follows the store by one main-actor turn).
        let pages = size.chromiumPages + size.webkitPages
        let listed = await Self.until { provider.generation > attempts && provider.status == .idle && provider.latestTabs.count == pages }
        try #require(listed, "fixture: the provider's list has \(provider.latestTabs.count) pages, not \(pages); status: \(provider.status)")
        let chromium = provider.latestTabs.filter { $0.engine == .cef }.map(\.targetID)
        try #require(chromium.count == size.chromiumPages, "fixture: \(chromium.count) Chromium pages in the list, not \(size.chromiumPages)")
        let leaving = try #require(chromium.first), incoming = try #require(chromium.last)
        try #require(leaving != incoming, "fixture: the session has one Chromium page")

        // The pane shows the leaving tab (no page is made: the test counts the host's reads, not a page's work).
        // No link yet: the provider keeps the tab's new fact, and the next link's first list carries it.
        let pane = HiddenPageHibernationTests.Pane()
        let cache: TabContentCache = services.cache
        cache.present(leaving, by: pane, presence: .visible)
        #expect(provider.latestTabs.first { $0.targetID == leaving }?.visible == true,
                "with no link, the provider did not keep that the tab shows: the next link would say it is hidden")

        // The provider's link: one end of a socket pair. A new link announces every listed tab.
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "fixture: socketpair failed (errno \(errno))")
        let reader = LinkReader(fd: fds[1])
        provider.connection = ProviderConnection(fd: fds[0])
        provider.refreshTabs()
        try #require(provider.announced.count == pages, "fixture: the new link announced \(provider.announced.count) tabs, not \(pages)")
        provider.send(.event(name: Self.endEvent, payload: .object([:])))
        let shown = await reader.events(through: Self.endEvent)
        try #require(shown.contains(LinkReader.Event(name: "tab.announced", target: leaving, visible: true)),
                     "fixture: the host was not told that the first tab shows; events: \(shown.count)")

        // THE SWITCH, one main-actor turn: the pane hides the leaving tab and shows the incoming one.
        let counted = CountedAccess(host.tabs)
        provider.accessSource = counted
        let passesBefore = provider.observation
        cache.withdraw(leaving, by: pane)
        cache.present(incoming, by: pane, presence: .visible)
        let passes = provider.observation - passesBefore
        let asked = counted.asked
        provider.accessSource = host.tabs

        provider.send(.event(name: Self.endEvent, payload: .object([:])))
        let events = await reader.events(through: Self.endEvent)
        // What the host must hear: the two tabs of the switch, in the order of the switch, and no other tab.
        #expect(events == [LinkReader.Event(name: "tab.announced", target: leaving, visible: false),
                           LinkReader.Event(name: "tab.announced", target: incoming, visible: true)],
                "the host did not get exactly the two tabs of the switch; events: \(events)")
        // What it must cost: the two tabs, at 60 workspaces as at 826.
        #expect(passes == 0, "the switch started \(passes) passes over the whole list (\(pages) pages) in its turn")
        #expect(asked.count <= 2 && Set(asked).isSubset(of: [leaving, incoming]),
                "the switch asked the extension access of \(asked.count) tabs (\(size.chromiumPages) Chromium pages in the session); it changed 2")

        cache.withdraw(incoming, by: pane)
        cache.removePresenter(pane)
        provider.dropConnection(reason: "the test ended")
        await reader.close()
    }
}

/// The host's end of the provider's link. Its reads block on the actor's executor (off the main actor, where the
/// provider runs). The test ends each read with a frame of its own, so no read waits for time to pass; the socket's
/// receive timeout only ends a run whose end frame never comes, so that run fails and does not hang.
private actor LinkReader {
    /// One event frame, with its `targetId` and `visible`.
    struct Event: Sendable, Equatable {
        var name: String
        var target: String?
        var visible: Bool?
    }

    private let fd: Int32
    private var decoder = ProviderFrameDecoder()

    init(fd: Int32) {
        self.fd = fd
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
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
                    if case .bool(let visible)? = fields["visible"] { event.visible = visible }
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
