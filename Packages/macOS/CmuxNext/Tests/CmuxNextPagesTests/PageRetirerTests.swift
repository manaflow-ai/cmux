import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// A closed page leaves the view tree in the close's turn and its engine page ends after it
/// (p13-webui-064, ``PageRetirer``): Cmd-W on a page tab makes 0 engine close calls in its turn, and a
/// page taken back before its teardown is never closed.
@MainActor
struct PageRetirerTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-retirer", resource: "page-retirer", processGroup: .solo, namespaces: [])

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
        WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), clock: PageTestClock.never,
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

    @Test func aReclaimedPageIsNeverClosed() {
        let retirer = Self.heldRetirer()
        let kept = NSView(), ended = NSView()
        var closed: [String] = []
        retirer.retire(kept) { closed.append("kept") }
        retirer.retire(ended) { closed.append("ended") }
        #expect(retirer.reclaim(kept))
        #expect(!retirer.isRetiring(kept))
        retirer.closeRetired()
        #expect(closed == ["ended"])
        #expect(!retirer.reclaim(kept), "a page reclaimed twice")
        #expect(!retirer.reclaim(ended), "a closed page was taken back")
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

    @Test func aPageTheHostTakesBackIsNeverClosed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        host.close(view)
        #expect(host.reclaim(view))
        #expect(host.openPages.map(ObjectIdentifier.init) == [ObjectIdentifier(view)])
        #expect(host.registry.pages(id: descriptor.id).contains { $0 === view })
        host.retirer.closeRetired()
        #expect(!page.closed, "the retirer closed a page the host took back")
        #expect(!host.reclaim(view), "an open page was taken back")
        host.close(view)
        host.retirer.closeRetired()
        #expect(page.closed)
    }
}
