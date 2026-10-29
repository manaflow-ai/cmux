import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// The layout notes each plan it applies on a shown screen, and each motion frame it steps, on the
/// scheduler's ``PlanApplyTurn`` until the turn's commit: a CLI, socket or agent
/// change opens no input turn, and the in-process CEF pump must still start no slice before its commit.
@MainActor
struct LayoutPlanApplyTurnTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let one = ScreenLayout.columns([LayoutColumn(id: "c1", width: 1, root: .leaf("a"))])
    static let two = ScreenLayout.columns([
        LayoutColumn(id: "c1", width: 0.5, root: .leaf("a")),
        LayoutColumn(id: "c2", width: 0.5, root: .leaf("b")),
    ])

    @Test func aProgramLayoutChangeAndAMotionFrameOpenThePlanApply() {
        _ = NSApplication.shared
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let turns = mainWork.budget.turns
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: Self.one)], activeScreenID: "s", focusedPane: "a")
        let root = LayoutRootView(model: model, contentProvider: Panes(), mainWork: mainWork)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true // the test is the clock
        defer { window.close() }
        turns.loopWoke() // a later turn: the first layout committed
        #expect(!mainWork.planApplies.isOpen)
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.two)]) // a program's change: no input turn
        root.syncWithModel()
        #expect(mainWork.planApplies.isOpen, "the apply is open until its turn's commit")
        turns.loopWillWait()
        turns.loopDidRender()
        turns.loopWoke()
        #expect(!mainWork.planApplies.isOpen, "committed")
        _ = root.advanceFrame(1.0 / 120)
        #expect(mainWork.planApplies.isOpen, "a motion frame is a plan apply too")
    }
}
