import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing

/// A closed page leaves the view tree in the close's turn and its engine page ends after it
/// (``PageRetirer``): Cmd-W on a page tab makes 0 engine close calls in its turn, 1 at the
/// retirer's deadline, and the page's routes and subscriptions end in the turn.
@MainActor
struct PageRetirerTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-retirer", resource: "page-retirer", processGroup: .solo,
                                            namespaces: ["test.retire."])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-retirer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A retirer whose deadline fires only when the test fires its rig (none here): the test runs the
    /// teardown with ``PageRetirer/closeRetired()``.
    private static func heldRetirer() -> PageRetirer {
        PageRetirer(deadlines: LifecycleDeadlineRig().scheduler)
    }

    private func makeHost(_ hosting: FakeChromiumHosting) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never,
                  retirer: Self.heldRetirer())
    }

    // MARK: The retirer

    @Test func retireDetachesNowAndClosesAtTheDeadline() {
        let retirer = Self.heldRetirer()
        let pane = NSView()
        let view = NSView()
        pane.addSubview(view)
        var closes = 0
        retirer.retire(view) { closes += 1 }
        #expect(view.superview == nil)
        #expect(closes == 0, "the retire's turn ran the teardown")
        #expect(retirer.isRetiring(view))
        retirer.closeRetired()
        #expect(closes == 1)
        #expect(retirer.count == 0)
        retirer.closeRetired()
        #expect(closes == 1, "a page closed twice")
    }

    @Test func aPageRetiredTwiceClosesOnce() {
        let retirer = Self.heldRetirer()
        let view = NSView()
        var closes: [String] = []
        retirer.retire(view) { closes.append("first") }
        retirer.retire(view) { closes.append("second") }
        #expect(retirer.count == 1)
        retirer.closeRetired()
        #expect(closes == ["first"])
    }

    /// The deadline runs the teardown, no sooner than ``PageRetirer/delay`` after the last retire.
    @Test func theDeadlineRunsTheTeardownAfterTheLastRetire() {
        let rig = LifecycleDeadlineRig()
        let retirer = PageRetirer(deadlines: rig.scheduler)
        let first = NSView(), second = NSView()
        var closed: [String] = []
        retirer.retire(first) { closed.append("first") }
        rig.advance(to: .milliseconds(300))
        retirer.retire(second) { closed.append("second") } // a burst of closes pushes the deadline back
        rig.advance(to: .milliseconds(600))
        rig.fire(movingTime: false)
        #expect(closed.isEmpty, "the teardown ran before the last retire's delay")
        rig.fire()
        #expect(closed == ["first", "second"])
        #expect(retirer.count == 0)
    }

    // MARK: The page host

    @Test func theHostsCloseDetachesThePageAndMakesNoEngineCloseInItsTurn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        let pane = NSView()
        pane.addSubview(view)
        host.close(view)
        #expect(view.superview == nil, "the closed page stayed in its pane")
        #expect(!page.closed, "the close's turn closed the engine page")
        #expect(host.openPages.isEmpty)
        #expect(host.registry.pages().isEmpty)
        #expect(host.retirer.isRetiring(view))
        host.retirer.closeRetired()
        #expect(page.closed, "the retirer's deadline left the engine page open")
    }

    /// The routes end in the close's turn, so a provider that forgot the page serves it nothing more; only the
    /// engine page waits for the deadline.
    @Test func theHostsCloseEndsTheRoutesAndSubscriptionsInItsTurn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let provider = CountedSubscriptions()
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root,
                                                          routes: [PageRoute(prefix: "test.retire.", provider: provider)])))
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        let reply = await view.router.handle(["t": "sub", "id": 1, "stream": "test.retire.changed"])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(provider.live == 1)
        host.close(view)
        #expect(provider.live == 0, "the closed page's subscription outlived the close's turn")
        #expect(view.router.subscriptionCount == 0)
        let late = await view.router.handle(["t": "sub", "id": 2, "stream": "test.retire.changed"])
        #expect(late["t"]?.stringValue == "err", "the closed page's router took a new watch")
        // A document its engine page still commits before the deadline (a load the close did not stop)
        // reopens nothing.
        view.documentCommitted()
        let afterCommit = await view.router.handle(["t": "sub", "id": 3, "stream": "test.retire.changed"])
        #expect(afterCommit["t"]?.stringValue == "err", "a late commit reopened the closed page's router")
        #expect(provider.live == 0)
        #expect(!page.closed, "the close's turn closed the engine page")
        host.retirer.closeRetired()
        #expect(page.closed)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The `debug.webui` count the bench's Cmd-W row reads: 0 engine closes inside the host's close, 1 at the
    /// deadline, stamped on the host's uptime.
    @Test func theHostCountsEachEngineCloseAndNoneInTheClosesTurn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        host.engineCloseUptime = { 42 }
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        await view.chromiumStart?.value
        host.close(view)
        #expect(host.engineCloses.total == 0)
        host.retirer.closeRetired()
        #expect(host.engineCloses.total == 1)
        #expect(host.engineCloses.inCloseTurn == 0, "the host's close ended an engine page in its turn")
        #expect(host.engineCloses.uptimes == [42])

        let report = WebUICensus(pages: host.registry.pages(), registry: host.registry, newTabSpare: nil, spareWindows: [],
                                 browserTabs: [], rendererProcess: { _ in (browserID: nil, clients: []) }, webKitPID: { _ in nil },
                                 retiring: host.retirer.count, engineCloses: host.engineCloses).report(helpers: [])
        let retire = try #require(report["retire"])
        #expect(retire["pending"]?.intValue == 0)
        #expect(retire["engine_closes"]?.intValue == 1)
        #expect(retire["engine_closes_in_close_turn"]?.intValue == 0)
        #expect(retire["engine_close_uptimes"]?.arrayValue?.compactMap(\.doubleValue) == [42])
    }

    /// A page its owner closes itself (no host close) ends at once and still counts, outside any close's turn.
    @Test func aPageClosedDirectlyEndsAtOnceAndCounts() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        view.close()
        #expect(page.closed)
        #expect(host.engineCloses.total == 1)
        #expect(host.engineCloses.inCloseTurn == 0)
    }
    #endif
}

/// A provider whose streams count while they live: the router's cancel ends one.
@MainActor
private final class CountedSubscriptions: PageProvider {
    private(set) var live = 0

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .null }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        live += 1
        return PageSubscription(frozenDelivery: .resync) { [weak self] in self?.live -= 1 }
    }
}
