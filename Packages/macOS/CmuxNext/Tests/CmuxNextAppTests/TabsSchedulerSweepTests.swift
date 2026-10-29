import AppKit
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextTabs
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextTabs sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9): one case
/// per migrated owner class. The page-decided close's deadline is in PageDecidedClosesTests.
/// - Hidden: the plus's settings observation on a hidden strip reads nothing until its node shows, then applies the
///   latest once (R-obs, rule 4).
/// - Person: the press-and-hold on + and on a chip are `userBlocking` deadlines a release cancels (R-timer, rule 6).
/// - Visible: the reorder settle is a `visible` deadline on the strip's placer.
/// - Window input state: strips follow their window's main role through one WindowEvents observer per notice (R-notif),
///   and a strip hidden with its ancestor leaves its hit tests by the cached shown state, no ancestor walk (R-vis).
@MainActor @Suite(.serialized) struct TabsSchedulerSweepTests {
    private static func strip(_ rig: MainDeadlineRig, node: VisibilityNode = VisibilityNode(root: "pane", own: .visible)) -> TabStripView {
        _ = NSApplication.shared
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t0"))
        return TabStripView(model: model, input: InputEventTap(), deadlines: rig.deadlines, visibilityNode: node)
    }

    // MARK: Hidden: the plus's settings (R-obs)

    @Test func aHiddenStripsPlusAppliesItsSettingOnlyWhenItShows() {
        DesignSettings.shared.plusButton = .hover
        defer { DesignSettings.shared.plusButton = .hover }
        let rig = MainDeadlineRig()
        let node = VisibilityNode(root: "pane", own: .hidden)
        let strip = Self.strip(rig, node: node)
        #expect(HoverReveal.owner(of: strip.newTabButton) != nil, "the first apply did not put the plus in the reveal")

        DesignSettings.shared.plusButton = .always
        rig.frame()
        #expect(HoverReveal.owner(of: strip.newTabButton) != nil, "a hidden strip applied a settings change")

        node.set(.visible)
        rig.frame()
        #expect(HoverReveal.owner(of: strip.newTabButton) == nil, "the shown strip did not apply the latest setting")
    }

    // MARK: Person: the holds (R-timer)

    @Test func theHoldsAreUserBlockingDeadlinesThatAReleaseCancels() {
        let rig = MainDeadlineRig()
        let strip = Self.strip(rig)
        #expect(strip.chipHold.workClass == .userBlocking, "the chip hold a person waits on is not the rest of their action")
        #expect(strip.reorderSettle.workClass == .visible)

        strip.pressedNewTab = true
        strip.newTabHold.start()
        #expect(rig.hasArmedWake, "holding + armed no deadline")
        #expect(!strip.newTabHold.end(), "a release before the hold's deadline showed the menu")
        #expect(!rig.hasArmedWake, "the release left the hold's wake armed")

        strip.startChipHold("g")
        #expect(strip.chipHold.isScheduled && rig.hasArmedWake, "a press on a chip armed no hold")
        strip.endPointerState()
        #expect(!strip.chipHold.isScheduled, "the strip leaving sight left the chip hold armed")

        // A hold whose press already ended does nothing at its deadline.
        strip.pressedNewTab = false
        strip.newTabHold.start()
        rig.fireAndRun()
        #expect(rig.elapsed >= 0.45, "the hold fired \(rig.elapsed) s in")
        #expect(!strip.newTabHold.end(), "a hold with no press showed the menu")
    }

    // MARK: Window input state (R-notif, R-vis)

    @Test func stripsFollowTheirWindowsMainRoleThroughOneObserverPerNotice() {
        let center = NotificationCenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let events = WindowEvents.of(window, center: center)
        let first = WindowMainObserver(), second = WindowMainObserver()
        var seen: [Bool] = []
        first.observe(window) { seen.append($0) }
        second.observe(window) { _ in }
        #expect(events.subscriberCount(NSWindow.didResignMainNotification) == 2)
        #expect(events.isObserving(NSWindow.didResignMainNotification), "the window's one fan-out observes the notice")

        center.post(name: NSWindow.didResignMainNotification, object: window)
        #expect(!first.isMain && !second.isMain, "a resign-main reached no strip")
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(first.isMain && seen.last == true)

        first.observe(nil) { _ in }
        #expect(events.subscriberCount(NSWindow.didResignMainNotification) == 1, "a strip that left kept its subscription")
    }

    @Test func aStripHiddenWithItsAncestorLeavesItsHitTestsWithNoWalk() {
        let rig = MainDeadlineRig()
        let strip = Self.strip(rig)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        window.contentView = host
        strip.frame = host.bounds
        host.addSubview(strip)
        #expect(strip.isShownInWindow)

        host.isHidden = true
        #expect(!strip.isShownInWindow, "the strip hidden with its ancestor still counts as shown")
        #expect(strip.target(atScreenPoint: window.convertPoint(toScreen: CGPoint(x: 20, y: 20)), verticalSlop: nil, groupWidth: nil) == nil,
                "a hidden strip took an external drop")
        host.isHidden = false
        #expect(strip.isShownInWindow, "the strip shown again did not count as shown")
    }
}
