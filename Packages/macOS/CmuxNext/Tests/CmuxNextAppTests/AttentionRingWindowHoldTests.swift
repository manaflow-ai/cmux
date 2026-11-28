import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextLayout
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/59901: switching to a workspace with a ringing pane drew the ring before
/// the workspace. The ring sits on the window's overlay plane, above the content and its page windows, while the window
/// keeps the outgoing workspace on screen until the incoming one's pages paint (``PanePaintHold``, up to 500 ms for a
/// page with no picture). The ring's hold ended after one frame (a warm switch) or never began (a cold one), so the
/// ring showed on the old workspace's picture until the new one appeared. It now draws with the new workspace.
@MainActor
@Suite(.serialized)
struct AttentionRingWindowHoldTests {
    /// Waits for `count` main run loop passes to commit their frames.
    private static func frameCommits(_ count: Int) async {
        for _ in 0..<count { await withCheckedContinuation { done in AfterFrameCommit().run { done.resume() } } }
    }

    /// Warm switch: b, parked, comes back while one of its pages has not painted, so the window keeps a on screen. b's
    /// ring stays hidden for as long as a shows, past the switch's own frame, and draws once b shows.
    @Test func aRingWaitsForTheWindowToShowItsWorkspace() async throws {
        let fixture = try await AttentionRingTimingTests.open(active: false)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b }, report: { "workspace b never showed" })
        let b = try #require(fixture.controller.content)
        let model = b.layoutModel
        let overlay = try #require(b.layoutView.context.hosts[pane]?.chrome, "b's pane has no overlay")
        try await PinnedPageTests.until({ model.attention[pane] != nil && overlay.attentionRingShown }, report: { "b's ring never drew" })
        fixture.controller.showWorkspace(requested: fixture.a.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.a })
        let a = try #require(fixture.controller.content)
        // A page in b that has not painted (a chat brand new, no picture of itself): the window keeps a until it does.
        let page = WorkspaceSwitchNoBlankFrameTests.UnpaintedPage(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        page.hasPicture = false
        b.contentView.addSubview(page)
        fixture.controller.root.paintHold.clock = ManualClock() // the hold's limit never passes on its own

        fixture.controller.showWorkspace(requested: fixture.b.id)
        #expect(fixture.controller.root.paintHold.kept === a.contentView, "the window did not keep a while b's page paints")
        #expect(model.holdsAttentionUntilShown && overlay.attentionLayer.isHidden, "b's ring drew in the switch's pass, over a")
        await Self.frameCommits(3)
        #expect(fixture.controller.root.paintHold.kept === a.contentView, "the window stopped keeping a before b's page painted")
        #expect(model.holdsAttentionUntilShown, "b's ring hold ended while the window still showed a")
        #expect(overlay.attentionLayer.isHidden, "b's ring drew on a's picture")

        page.paint() // the window shows b after its layout pass
        try await PinnedPageTests.until({ fixture.controller.root.paintHold.kept == nil }, report: { "b's page painted and the window still kept a" })
        try await PinnedPageTests.until({ !model.holdsAttentionUntilShown }, report: { "b's ring never drew once b showed" })
        #expect(model.attention[pane] != nil, "b's ring went instead of drawing")
        #expect(!overlay.attentionLayer.isHidden, "b's ring stayed hidden after b showed")
    }

    /// Cold switch: b's content is built by the switch itself. Its ring is held in the switch's pass like a warm one's,
    /// not drawn on the overlay before b's first frame.
    @Test func aColdWorkspacesRingWaitsForItsFirstFrame() async throws {
        let fixture = try await AttentionRingTimingTests.open(active: false)
        defer { fixture.close() }
        let pane = LayoutPaneID(fixture.ringing.id)
        #expect(fixture.controller.parked[fixture.b.id] == nil, "b was built before the switch")
        fixture.controller.showWorkspace(requested: fixture.b.id)
        let model = try #require(fixture.controller.content?.layoutModel)
        #expect(fixture.controller.content?.workspace === fixture.b)
        #expect(model.holdsAttentionUntilShown, "a cold switch drew b's rings before b's first frame")
        if let overlay = fixture.controller.content?.layoutView.context.hosts[pane]?.chrome {
            #expect(overlay.attentionLayer.isHidden, "b's ring is on the overlay in the switch's own pass")
        }
        try await PinnedPageTests.until({ !model.holdsAttentionUntilShown }, report: { "the hold never ended" })
        try await PinnedPageTests.until({ model.attention[pane] != nil }, report: { "b's unread pane never rang" })
        let overlay = try #require(fixture.controller.content?.layoutView.context.hosts[pane]?.chrome, "b's pane has no overlay")
        #expect(!overlay.attentionLayer.isHidden, "b's ring stayed hidden after its frame")
    }

    /// A switch away before the held workspace showed: its pending release does nothing, and coming back holds again.
    @Test func aSwitchAwayBeforeTheWorkspaceShowedLeavesNoStaleRelease() async throws {
        let fixture = try await AttentionRingTimingTests.open(active: false)
        defer { fixture.close() }
        fixture.controller.showWorkspace(requested: fixture.b.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.b })
        let b = try #require(fixture.controller.content)
        fixture.controller.showWorkspace(requested: fixture.a.id)
        try await PinnedPageTests.until({ fixture.controller.content?.workspace === fixture.a })
        let page = WorkspaceSwitchNoBlankFrameTests.UnpaintedPage(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        page.hasPicture = false
        b.contentView.addSubview(page)
        fixture.controller.root.paintHold.clock = ManualClock()
        fixture.controller.showWorkspace(requested: fixture.b.id)
        #expect(b.layoutModel.holdsAttentionUntilShown)
        fixture.controller.showWorkspace(requested: fixture.a.id) // b never showed
        #expect(!b.layoutModel.holdsAttentionUntilShown, "a parked workspace kept its ring hold")
        page.removeFromSuperview()
        await Self.frameCommits(2)
        fixture.controller.showWorkspace(requested: fixture.b.id)
        #expect(b.layoutModel.holdsAttentionUntilShown, "coming back did not hold b's rings")
        try await PinnedPageTests.until({ !b.layoutModel.holdsAttentionUntilShown }, report: { "the hold never ended" })
    }
}
