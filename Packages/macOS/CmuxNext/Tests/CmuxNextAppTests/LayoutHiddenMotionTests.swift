import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// Lucas 2026-10-19: a workspace showed nothing, its pane parked one width off the left edge. Its
/// columns had collapsed to one pane as it was hidden; the pane's spring started from where it
/// showed, the hidden workspace's clock stopped, and showing it again never restarted it. Hiding
/// a layout now ends its motion where it was going.
@MainActor
struct LayoutHiddenMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Screens {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("p1"))),
                                          LayoutScreen(id: "s2", name: "s2", layout: .splits(.leaf("p2")))],
                                activeScreenID: "s1", focusedPane: "p1")
        let root: LayoutRootView
        let window: NSWindow

        init() {
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }
    }

    @Test func showingAfterAnInterruptedScreenSwitchFinishesTheTransition() throws {
        let fixture = Screens()
        let root = fixture.root
        let incoming = try #require(root.screenViews["s2"])
        let outgoing = try #require(root.screenViews["s1"])
        fixture.model.selectScreen("s2")
        root.syncWithModel()
        #expect(incoming.alphaValue == 0)
        #expect(!incoming.hasMotion)
        #expect(root.driver.isRunning)

        // No frame or layout pass may finish the transition before the workspace parks.
        root.isHidden = true
        #expect(!root.driver.isRunning)
        root.isHidden = false
        #expect(root.isLive)
        #expect(root.driver.isRunning, "the incoming screen needs scheduled frames even when its panes are settled")
        let scheduler = FrameScheduler.forWindow(fixture.window)
        for tick in 0..<240 {
            if !root.driver.isRunning { break }
            scheduler.frameDidFire(timestamp: Double(tick) / 120)
        }
        #expect(!incoming.isHidden)
        #expect(incoming.alphaValue == 1)
        #expect(incoming.frame.origin == root.bounds.origin)
        #expect(outgoing.isHidden)
        #expect(!root.driver.isRunning)
    }

    @Test func showingAnUnchangedSettledRootLeavesTheDriverIdle() {
        let fixture = Screens()
        let root = fixture.root
        let moving = root.screenViews.values.contains(where: \.hasMotion)
        #expect(!moving)
        #expect(!root.driver.isRunning)
        root.isHidden = true
        root.isHidden = false
        #expect(root.isLive)
        #expect(root.driver.isAttached)
        #expect(!root.driver.isRunning)
    }

    @Test func hidingTheLayoutEndsItsMotion() {
        let split: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p1"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(split))], activeScreenID: "s",
                                focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        // The test is the clock: the display link never ticks.
        root.driver.isManual = true

        // p2 closes: p1 springs from the right half over the whole screen.
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))])
        root.syncWithModel()
        let screen = root.screenViews["s"]
        #expect(screen?.hasMotion == true)

        root.isHidden = true
        #expect(screen?.hasMotion == false)
        let frame = screen?.paneFrames["p1"]
        #expect(frame != nil && frame?.rect == frame?.targetRect)
    }

    // MARK: Automation bursts (p06-scheduler-038)

    /// One screen of one pane in a window, with the test as the clock and the frame counter.
    @MainActor
    final class Burst {
        final class FrameCounter {
            var value = 0
        }

        let frames = FrameCounter()
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))], activeScreenID: "s",
                                focusedPane: "p1")
        let root: LayoutRootView
        let window: NSWindow
        let burst: LayoutAutomationBurst

        init() {
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            burst = LayoutAutomationBurst(frame: { [frames] in frames.value })
            model.automationBurst = burst
        }

        /// `panes` panes side by side: p1 split once per pane after it, as the App applies a split.
        func split(into panes: Int, cause: ObservationCause) {
            var node: SplitNode = .leaf(PaneID("p\(panes)"))
            for index in stride(from: panes - 1, through: 1, by: -1) {
                node = .split(SplitID("h\(index)"), axis: .horizontal, ratio: 0.5, a: .leaf(PaneID("p\(index)")), b: node)
            }
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(node))], cause: cause)
            root.syncWithModel()
        }

        var screen: ScreenContentView? { root.screenViews["s"] }
    }

    @Test func fiveAutomationSplitsInOneFrameLandWithNoSpring() throws {
        let fixture = Burst()
        for panes in 2...6 { fixture.split(into: panes, cause: .automation) }
        let screen = try #require(fixture.screen)
        #expect(screen.hasMotion == false, "the burst's later splits land the first one's spring too")
        #expect(fixture.burst.snapped == 4)
        #expect(screen.paneFrames.count == 6)
        #expect(screen.paneFrames.values.allSatisfy { $0.rect == $0.targetRect })
    }

    @Test func aPersonsSplitSpringsInAnAutomationBurst() throws {
        let fixture = Burst()
        for panes in 2...4 { fixture.split(into: panes, cause: .automation) }
        fixture.split(into: 5, cause: .person)
        #expect(try #require(fixture.screen).hasMotion)
        #expect(fixture.burst.snapped == 2)
    }

    @Test func onePersonSplitSprings() throws {
        let fixture = Burst()
        fixture.split(into: 2, cause: .person)
        #expect(try #require(fixture.screen).hasMotion)
        #expect(fixture.burst.snapped == 0)
    }

    @Test func oneAutomationSplitPerFrameSprings() throws {
        let fixture = Burst()
        fixture.split(into: 2, cause: .automation)
        fixture.frames.value += 1
        fixture.split(into: 3, cause: .automation)
        #expect(try #require(fixture.screen).hasMotion)
        #expect(fixture.burst.snapped == 0)
    }

    @Test func aRatioChangeDoesNotCountTowardTheBurst() {
        let fixture = Burst()
        fixture.split(into: 2, cause: .automation)
        let resized: SplitNode = .split("h1", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))
        fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(resized))], cause: .automation)
        fixture.root.syncWithModel()
        fixture.split(into: 3, cause: .automation)
        #expect(fixture.burst.snapped == 1, "only the second structural change of the frame lands at once")
    }
}
