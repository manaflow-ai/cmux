import CmuxNextDaemon
import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBridge

private func context(paneTabs: Int = 3, workspaceTabs: Int = 5, dragged: Int = 1) -> TabDragContext {
    TabDragContext(sourcePaneID: "pane-a", sourcePaneTabCount: paneTabs, sourceWorkspaceID: "ws-1",
                   sourceWorkspaceTabCount: workspaceTabs, draggedTabCount: dragged)
}

private func proposal(_ kind: TabDropKind, ghost: CGRect? = nil) -> TabDropProposal {
    TabDropProposal(kind: kind, highlightFrame: CGRect(x: 0, y: 0, width: 10, height: 10), ghostFrame: ghost)
}

struct TabDragResolverTests {
    let strip = UUID()

    @Test func firstAcceptedProposalWinsInPriorityOrder() {
        let proposals: [TabDropProposal?] = [
            nil,
            proposal(.strip(stripID: strip, index: 2, groupID: nil)),
            proposal(.newSplit(paneID: "pane-b", edge: .left)),
        ]
        #expect(TabDragResolver.winner(proposals, context: context()) == 1)
    }

    @Test func rejectedProposalFallsThroughToTheNextSurface() {
        let proposals: [TabDropProposal?] = [
            proposal(.workspace(id: "ws-1")),
            proposal(.newSplit(paneID: "pane-b", edge: .right)),
        ]
        #expect(TabDragResolver.winner(proposals, context: context()) == 1)
    }

    @Test func eachProposalKindMapsToItsOutcome() {
        let ctx = context()
        let point = CGPoint(x: 5, y: 5)
        func outcome(_ kind: TabDropKind) -> TabDragOutcome {
            TabDragResolver.outcome(for: proposal(kind), insideWindow: true, screenPoint: point, context: ctx)
        }
        #expect(outcome(.strip(stripID: strip, index: 1, groupID: "g")) == .strip(stripID: strip, index: 1, groupID: "g"))
        #expect(outcome(.newSplit(paneID: "pane-b", edge: .top)) == .newSplit(paneID: "pane-b", edge: .top))
        #expect(outcome(.newColumn(screenID: "s", afterColumnID: "c1")) == .newColumn(screenID: "s", afterColumnID: "c1"))
        #expect(outcome(.newWorkspace(groupID: nil, index: 3)) == .newWorkspace(groupID: nil, index: 3))
        #expect(outcome(.newWorkspace(groupID: "grp", index: -1)) == .newWorkspace(groupID: "grp", index: nil))
        #expect(outcome(.workspace(id: "ws-2")) == .workspace(id: "ws-2"))
    }

    @Test func splittingTheSourcePaneWithItsOnlyTabIsANoOp() {
        let ctx = context(paneTabs: 1)
        for edge in [TabDropEdge.left, .right, .top, .bottom] {
            #expect(!TabDragResolver.accepts(.newSplit(paneID: "pane-a", edge: edge), context: ctx))
            #expect(TabDragResolver.outcome(for: proposal(.newSplit(paneID: "pane-a", edge: edge)), insideWindow: true,
                                            screenPoint: .zero, context: ctx) == .cancel)
        }
        #expect(TabDragResolver.accepts(.newSplit(paneID: "pane-a", edge: .left), context: context(paneTabs: 2)))
        #expect(TabDragResolver.accepts(.newSplit(paneID: "pane-b", edge: .left), context: ctx))
    }

    @Test func groupDragThatEmptiesItsPaneCannotSplitThatPane() {
        let ctx = context(paneTabs: 3, dragged: 3)
        #expect(!TabDragResolver.accepts(.newSplit(paneID: "pane-a", edge: .left), context: ctx))
    }

    @Test func movingIntoTheOwnWorkspaceIsRejected() {
        #expect(!TabDragResolver.accepts(.workspace(id: "ws-1"), context: context()))
        #expect(TabDragResolver.accepts(.workspace(id: "ws-2"), context: context()))
    }

    @Test func columnBeforeTheFirstIsRejected() {
        #expect(!TabDragResolver.accepts(.newColumn(screenID: "s", afterColumnID: nil), context: context()))
    }

    @Test func insideAWindowWithNoTargetCancels() {
        #expect(TabDragResolver.outcome(for: nil, insideWindow: true, screenPoint: .zero, context: context()) == .cancel)
    }

    @Test func releaseOutsideEveryWindowTearsOff() {
        let point = CGPoint(x: 900, y: 300)
        #expect(TabDragResolver.outcome(for: nil, insideWindow: false, screenPoint: point, context: context()) == .tearOff(screenPoint: point))
    }

    @Test func tearingOffTheWholeWorkspaceMovesTheWindowInstead() {
        let point = CGPoint(x: 900, y: 300)
        let ctx = context(paneTabs: 1, workspaceTabs: 1)
        #expect(TabDragResolver.outcome(for: nil, insideWindow: false, screenPoint: point, context: ctx) == .moveWindow(screenPoint: point))
    }
}

struct TabDragLifecycleTests {
    final class Counter {
        var restores = 0
    }

    private func make(_ counter: Counter) -> TabDragLifecycle {
        var next = 0
        return TabDragLifecycle(makeTransaction: {
            next += 1
            return ClientTransactionID(rawValue: "t\(next)")
        }, restore: { counter.restores += 1 })
    }

    @Test func cancelRestoresExactlyOnce() {
        let counter = Counter()
        let lifecycle = make(counter)
        lifecycle.cancel()
        lifecycle.cancel()
        #expect(counter.restores == 1)
        #expect(lifecycle.phase == .restored)
        #expect(lifecycle.beginCommit() == nil)
    }

    @Test func acceptedCommitNeverRestores() {
        let counter = Counter()
        let lifecycle = make(counter)
        let transaction = try! #require(lifecycle.beginCommit())
        #expect(lifecycle.transaction == transaction)
        #expect(!lifecycle.isEnded)
        lifecycle.settle(transaction, ok: true)
        lifecycle.cancel()
        lifecycle.settle(transaction, ok: false)
        #expect(counter.restores == 0)
        #expect(lifecycle.phase == .settled)
    }

    @Test func rejectedCommitRestoresOnce() {
        let counter = Counter()
        let lifecycle = make(counter)
        let transaction = try! #require(lifecycle.beginCommit())
        lifecycle.settle(transaction, ok: false)
        lifecycle.settle(transaction, ok: false)
        #expect(counter.restores == 1)
        #expect(lifecycle.phase == .restored)
    }

    @Test func settleForAnotherTransactionIsIgnored() {
        let counter = Counter()
        let lifecycle = make(counter)
        _ = lifecycle.beginCommit()
        lifecycle.settle(ClientTransactionID(rawValue: "stale"), ok: false)
        #expect(counter.restores == 0)
        #expect(!lifecycle.isEnded)
    }

    @Test func cancelDuringCommitDoesNothing() {
        let counter = Counter()
        let lifecycle = make(counter)
        let transaction = try! #require(lifecycle.beginCommit())
        lifecycle.cancel()
        #expect(counter.restores == 0)
        lifecycle.settle(transaction, ok: true)
        #expect(lifecycle.isEnded)
    }
}

struct TabMoveIndexTests {
    @Test func samePaneMoveRightAddsOneForPreMoveCoordinates() {
        // [A,B,C]: A to final index 1 -> wire 2 (daemon removes A, subtracts one).
        #expect(TabMoveIndex.wireIndex(finalIndex: 1, currentIndex: 0) == 2)
        #expect(TabMoveIndex.wireIndex(finalIndex: 2, currentIndex: 0) == 3)
    }

    @Test func samePaneMoveLeftAndNoOpKeepTheIndex() {
        #expect(TabMoveIndex.wireIndex(finalIndex: 0, currentIndex: 2) == 0)
        #expect(TabMoveIndex.wireIndex(finalIndex: 1, currentIndex: 1) == 1)
    }

    @Test func crossPaneMoveUsesTheFinalIndex() {
        #expect(TabMoveIndex.wireIndex(finalIndex: 3, currentIndex: nil) == 3)
    }
}

struct TabDragGhostMotionTests {
    let tab = CGRect(x: 100, y: 100, width: 120, height: 28)

    @Test func pointerMotionTracksWithoutLag() {
        var motion = TabDragGhostMotion(rect: tab, cardness: 1)
        let moved = tab.offsetBy(dx: 40, dy: -10)
        motion.setTarget(moved, cardness: 1, jump: false)
        #expect(motion.presentedRect == moved)
    }

    @Test func modeSwitchStartsWhereTheGhostWasAndSettlesOnTheTarget() {
        var motion = TabDragGhostMotion(rect: tab, cardness: 1)
        let slot = CGRect(x: 300, y: 400, width: 160, height: 30)
        motion.setTarget(slot, cardness: 0, jump: true)
        #expect(motion.presentedRect == tab)
        #expect(motion.presentedCardness == 1)
        var frames = 0
        while motion.step(1.0 / 120.0), frames < 600 { frames += 1 }
        #expect(frames < 240, "settles within 2 s at 120 Hz")
        #expect(motion.presentedRect == slot)
        #expect(motion.presentedCardness == 0)
        #expect(motion.isSettled)
    }

    @Test func reduceMotionSnaps() {
        var motion = TabDragGhostMotion(rect: tab, cardness: 1, reduceMotion: true)
        let slot = CGRect(x: 300, y: 400, width: 160, height: 30)
        motion.setTarget(slot, cardness: 0, opacity: 0, jump: true)
        #expect(motion.presentedRect == slot)
        #expect(motion.presentedOpacity == 0)
        let moving = motion.step(1.0 / 120.0)
        #expect(!moving)
    }
}

struct TabDragGeometryTests {
    @Test func inlineRectKeepsTheGrabFractionAndTakesTheSlotRow() {
        let rect = TabDragGeometry.inlineRect(pointer: CGPoint(x: 500, y: 612), grabOffset: CGPoint(x: 30, y: 10),
                                              tabSize: CGSize(width: 120, height: 28),
                                              slot: CGRect(x: 440, y: 600, width: 240, height: 30))
        #expect(rect == CGRect(x: 440, y: 600, width: 240, height: 30))
    }

    @Test func tearOffFramePutsTheTabUnderThePointer() {
        let visible = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        let frame = TabDragGeometry.tearOffFrame(pointer: CGPoint(x: 1000, y: 1000), grabOffset: CGPoint(x: 20, y: 10),
                                                 tabSize: CGSize(width: 120, height: 28), tabOffset: CGPoint(x: 240, y: 32),
                                                 windowSize: CGSize(width: 1100, height: 720), visible: visible)
        // Tab top-left lands at (980, 1018): window top-left is 240 left and 32 up of it.
        #expect(frame.minX == 740)
        #expect(frame.maxY == 1050)
        #expect(frame.size == CGSize(width: 1100, height: 720))
    }

    @Test func tearOffFrameStaysOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = TabDragGeometry.tearOffFrame(pointer: CGPoint(x: 1430, y: 890), grabOffset: .zero,
                                                 tabSize: CGSize(width: 120, height: 28), tabOffset: CGPoint(x: 240, y: 32),
                                                 windowSize: CGSize(width: 1100, height: 720), visible: visible)
        #expect(visible.contains(frame))
    }
}
