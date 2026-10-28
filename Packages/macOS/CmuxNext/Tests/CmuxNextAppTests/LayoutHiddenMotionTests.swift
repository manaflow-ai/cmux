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
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
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
        let root = LayoutRootView(model: model, contentProvider: Panes(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
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

    // MARK: Automation bursts

    /// One screen of one pane in a window, bursts on (`automationBurstSnap`), with the test as the
    /// display clock and the burst clock.
    @MainActor
    final class Burst {
        final class Clock {
            var now: CFTimeInterval = 100
        }

        let clock = Clock()
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))], activeScreenID: "s",
                                focusedPane: "p1")
        let root: LayoutRootView
        let window: NSWindow

        init() {
            model.snapsAutomationBursts = true
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.burstClock = { [clock] in clock.now }
        }

        /// `panes` panes side by side (p1 split once per pane after it), applied as the App applies
        /// a daemon tree: the model, then the view's sync.
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

    /// Five automation splits that coalesced into one apply (one drain) start no spring and lay
    /// out once.
    @Test func fiveAutomationSplitsInOneFrameStartNoSpringAndLayOutOnce() throws {
        let fixture = Burst()
        let screen = try #require(fixture.screen)
        let passes = screen.reconcilePasses
        fixture.split(into: 6, cause: .automation)
        #expect(!screen.hasMotion, "a spring started")
        #expect(screen.reconcilePasses - passes == 1, "\(screen.reconcilePasses - passes) layout passes")
        #expect(fixture.root.automationBurstSnaps == 1)
        #expect(screen.paneFrames.count == 6)
        #expect(screen.paneFrames.values.allSatisfy { $0.rect == $0.targetRect })
    }

    /// One automation split per frame: the first springs as a person's would, every later one in
    /// the burst lands at once (with the spring in flight), none restarts a spring.
    @Test func automationSplitsOnePerFrameSpringOnce() throws {
        let fixture = Burst()
        let screen = try #require(fixture.screen)
        fixture.split(into: 2, cause: .automation)
        #expect(screen.hasMotion, "the first automation split springs")
        for panes in 3...6 {
            fixture.clock.now += 1.0 / 120
            fixture.split(into: panes, cause: .automation)
            #expect(!screen.hasMotion, "split \(panes - 1) of the burst started a spring")
        }
        #expect(fixture.root.automationBurstSnaps == 4)
        #expect(screen.paneFrames.values.allSatisfy { $0.rect == $0.targetRect })
    }

    @Test func onePersonSplitSprings() throws {
        let fixture = Burst()
        fixture.split(into: 2, cause: .person)
        #expect(try #require(fixture.screen).hasMotion)
        #expect(fixture.root.automationBurstSnaps == 0)
    }

    /// A person's split in the middle of an agent's burst springs, and the agent's next split
    /// starts a new burst.
    @Test func aPersonsSplitSpringsInAnAutomationBurst() throws {
        let fixture = Burst()
        let screen = try #require(fixture.screen)
        fixture.split(into: 2, cause: .automation)
        fixture.split(into: 3, cause: .automation)
        #expect(fixture.root.automationBurstSnaps == 1)
        fixture.split(into: 4, cause: .person)
        #expect(screen.hasMotion)
        #expect(fixture.root.automationBurstSnaps == 1)
    }

    /// A single automation split after a pause longer than a split's spring springs again.
    @Test func anAutomationSplitAfterAPauseSprings() throws {
        let fixture = Burst()
        fixture.split(into: 2, cause: .automation)
        fixture.clock.now += 10
        fixture.split(into: 3, cause: .automation)
        #expect(try #require(fixture.screen).hasMotion)
        #expect(fixture.root.automationBurstSnaps == 0)
    }

    /// A ratio change is not structural: it neither snaps nor counts toward a burst's panes.
    @Test func aRatioChangeIsNotPartOfTheBurst() {
        let fixture = Burst()
        fixture.split(into: 2, cause: .automation)
        fixture.clock.now += 10
        let resized: SplitNode = .split("h1", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))
        fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(resized))], cause: .automation)
        fixture.root.syncWithModel()
        #expect(fixture.root.automationBurstSnaps == 0)
    }

    /// With the feature off, an agent's coalesced splits spring as before.
    @Test func burstsOffSpringAsBefore() throws {
        let fixture = Burst()
        fixture.model.snapsAutomationBursts = false
        fixture.split(into: 6, cause: .automation)
        #expect(try #require(fixture.screen).hasMotion)
        #expect(fixture.root.automationBurstSnaps == 0)
    }
}
