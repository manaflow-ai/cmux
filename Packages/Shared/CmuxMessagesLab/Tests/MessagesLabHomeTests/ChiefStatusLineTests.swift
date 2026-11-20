import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// v3f P1-4 and the P2 bottom items: "Waiting for you" leaves the transcript with the decision (no
/// ghost row), the transcript makes room for "Working · Ns", and a band hides rows under the field.
@MainActor @Suite(.serialized) struct ChiefStatusLineTests {
    typealias Geometry = ChiefTranscriptGeometryTests

    static func noticeRows(_ demo: MessagesWindowView) -> [TranscriptModel.Row] {
        demo.model.rows.filter { if case .notice = $0.spec.kind { return true }; return false }
    }

    // MARK: Waiting for you

    /// P1-4 (e1): once the approval resolves, the status line's row is gone from the model at once:
    /// no ghost stays to fade (Home's ghost was still drawn 24 s later under the next rows).
    @Test func theStatusLineLeavesWithNoGhost() {
        let controller = Geometry.pane(count: 4)
        guard let demo = controller.demo else { Issue.record("no window view"); return }
        #expect(demo.cmuxNoticeOffAtOnce)
        controller.dispatch(.setNotice(CmuxStrings.waitingForYou))
        let shown = Self.noticeRows(demo)
        #expect(shown.count == 1)
        #expect(shown.first?.ghost == false)
        controller.dispatch(.setNotice(nil))
        #expect(Self.noticeRows(demo).isEmpty)
        #expect(!demo.model.hasGhosts)
        // The visible cells hold no status line either.
        demo.collection.layoutIfNeeded()
        let drawn = demo.collection.visibleCells.compactMap { ($0 as? RowCell)?.spec }
        #expect(!drawn.contains { if case .notice = $0.kind { return true }; return false })
    }

    /// Without the Home flag the upstream fade (a ghost row) is kept.
    @Test func upstreamKeepsItsFadingGhost() {
        let controller = Geometry.pane(count: 4)
        guard let demo = controller.demo else { Issue.record("no window view"); return }
        demo.cmuxNoticeOffAtOnce = false
        controller.dispatch(.setNotice(CmuxStrings.waitingForYou))
        controller.dispatch(.setNotice(nil))
        #expect(Self.noticeRows(demo).allSatisfy { $0.ghost })
        #expect(Self.noticeRows(demo).count == 1)
    }

    // MARK: Working · Ns

    /// P2 (b1): the room under the newest row moves a pinned transcript up by the inset, and back.
    @Test func theBottomInsetLiftsThePinnedRows() {
        let controller = Geometry.pane(count: 30)
        guard let demo = controller.demo, let store = controller.store else { Issue.record("no window view"); return }
        #expect(store.state.ui.scroll.pinnedToBottom)
        let pinned = demo.pinnedOffset
        controller.transcriptBottomInset = 6
        #expect(demo.cmuxBottomInset == 6)
        #expect(abs(demo.pinnedOffset - (pinned + 6)) < 0.01)
        #expect(abs(demo.collection.contentOffset.y - demo.pinnedOffset) < 1)
        // A later commit keeps the room (every bottom pad adds it).
        Geometry.receive(controller, 1)
        #expect(abs(demo.collection.contentOffset.y - demo.pinnedOffset) < 1)
        let withRoom = demo.pinnedOffset
        controller.transcriptBottomInset = 0
        #expect(abs(demo.pinnedOffset - (withRoom - 6)) < 0.01)
    }

    /// The inset set before the window view exists reaches it at install.
    @Test func anEarlyInsetReachesTheWindowView() {
        let host = HostView(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
        let controller = ChatController(host: host, wake: Geometry.NoWake())
        controller.transcriptBottomInset = 6
        var core = ProjectionCore(me: HomeHarnessTests.me)
        let items: [TranscriptItem] = Array(HomeHarnessTests.base.prefix(3))
        let (conv, w) = core.install(HomeHarnessTests.id, items: items, summary: HomeHarnessTests.summary(lastSeq: Seq(3)))
        controller.install(conv, windowStart: w.start, total: w.total)
        #expect(controller.demo?.cmuxBottomInset == 6)
    }

    // MARK: Bottom bleed

    @Test func theFooterBandCoversTheFieldAndWhatIsUnderIt() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 700)
        let band = FooterFadeView.frame(fieldTop: 640, in: bounds)
        #expect(band.minY == 640 - FooterFadeView.fadeLength)
        #expect(band.maxY == 700)
        #expect(band.width == 600)
        // A field top outside the pane stays in it.
        #expect(FooterFadeView.frame(fieldTop: 900, in: bounds).maxY == 700)
        #expect(FooterFadeView.frame(fieldTop: -5, in: bounds).minY == 0)
    }

    @Test func theFooterBandShowsOnlyOverRowsUnderTheField() {
        #expect(FooterFadeView.revealed(hasFill: true, offset: 100, pinnedOffset: 400))
        #expect(!FooterFadeView.revealed(hasFill: true, offset: 400, pinnedOffset: 400))
        #expect(!FooterFadeView.revealed(hasFill: false, offset: 100, pinnedOffset: 400))
        #expect(!FooterFadeView.revealed(hasFill: true, offset: .nan, pinnedOffset: 400))
    }

    @Test func aPinnedPaneHidesTheBandAndItSitsOverTheRows() {
        let controller = Geometry.pane(count: 30)
        let host = controller.host
        host.footerFade.setFill(.black, maxAlpha: 0.94)
        host.applyFooterFade()
        #expect(!host.footerFade.isRevealed)
        guard let demo = controller.demo else { Issue.record("no window view"); return }
        #expect(abs(host.footerFade.frame.minY - (demo.fieldTop - FooterFadeView.fadeLength)) < 0.01)
        // Over the rows' views, under the flying bubble and the field.
        let order = host.subviews
        guard let fade = order.firstIndex(of: host.footerFade), let scroll = order.firstIndex(of: host.scrollView),
              let morph = order.firstIndex(of: host.morphHost), let field = order.firstIndex(of: host.fieldChrome) else {
            Issue.record("missing views"); return
        }
        #expect(scroll < fade && fade < morph && fade < field)
        #expect(host.footerFade.hitTest(CGPoint(x: 10, y: 10)) == nil)
    }
}
