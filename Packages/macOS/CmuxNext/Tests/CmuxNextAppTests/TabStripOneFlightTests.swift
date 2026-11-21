import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// One motion in flight on a tab strip (decided 2026-11-16): a strip shows at most one move at a time, and a held
/// key shows one motion and then none.
///
/// The rule is cmux-motion's `MotionFlight`. At rest, a change starts the strip's move. In a move, a change by
/// another act or by no act (a close after an open, a reorder) starts the one move again from the place of now. In
/// a move, a change by the same act (the second key of a held New Tab or Close Tab) puts each tab at its rest
/// place in that frame, and so does each next change by that act until one motion length passed with none.
///
/// A strip move is the set of animations that one change adds to the tabs' layers (`TabStripMove`, keys with the
/// prefix `tab.move.`). "One move" is counted on the layers: no layer has two strip moves on one key path.
///
/// The test is the clock (`TabStripMoveSource.now`): no sleep, no poll, no wall time. A strip in no window animates
/// as one on screen does (`Motion.canAnimate`), and no run loop turns in a test, so no animation ends by itself:
/// each count is what the changes left on the layers.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct TabStripOneFlightTests {
    /// The clock that the test gives the strip. It starts at the host's media time, read one time, so that the
    /// strip's own reads of that clock (a mask's path, a closing tab's end) are near it; then only the test moves it.
    final class Clock {
        var now = CACurrentMediaTime()
    }

    /// One refresh of a 60 Hz display: the time between two repeats of a held key is longer.
    static let frame = 1.0 / 60

    static func tab(_ index: Int) -> TabItem {
        TabItem(id: TabID("tab\(index)"), title: "python3 /tmp/sigwinch.py --seed 100\(index)")
    }

    /// Runs `body` on a pane's strip with `count` tabs at rest, the first one selected, with the motion of a new
    /// tab on. The strip is in no window; its moves start at `clock.now`.
    static func withStrip(tabs count: Int, _ body: (TabStripModel, TabStripView, Clock) throws -> Void) throws {
        // Synchronous from here to the resets: the overrides are process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let enabledAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newTab)
        defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
        try #require(Motion.tabs.animatesMovement, "SETUP: the animation speed is off on this host")
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let model = TabStripModel(tabs: (0..<count).map(tab), selectedID: tab(0).id)
        let pane = PaneContentView(stripModel: model, reveal: reveal)
        pane.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        let strip = pane.stripView
        let clock = Clock()
        strip.moveSource.now = { clock.now }
        strip.sync(fromModel: true)
        pane.layoutSubtreeIfNeeded()
        try withExtendedLifetime(pane) { try body(model, strip, clock) }
    }

    /// The strip moves on the tabs' layers: how many animations have a `TabStripMove` key, and the most of them
    /// that animate one key path of one layer (with one move in flight: 1).
    static func moves(_ strip: TabStripView) -> (count: Int, mostOnOneKeyPath: Int) {
        var count = 0, most = 0
        for cell in strip.cells.values {
            var onKeyPath: [String: Int] = [:]
            for key in cell.layer.animationKeys() ?? [] where key.hasPrefix(TabStripMove.keyPrefix) {
                count += 1
                let keyPath = (cell.layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath ?? key
                onKeyPath[keyPath, default: 0] += 1
            }
            most = max(most, onKeyPath.values.max() ?? 0)
        }
        return (count, most)
    }

    /// Where each tab shows at `time`: its model frame and each animation on its layer (`MotionPath`).
    static func shown(_ strip: TabStripView, at time: CFTimeInterval) -> [TabID: CGRect] {
        strip.cells.mapValues { TabOcclusion.Path($0, now: time).frame(at: time) }
    }

    /// The tabs that do not show at their rest place at `time`, with how far off each is (x, width).
    static func offRest(_ strip: TabStripView, at time: CFTimeInterval) -> [String] {
        shown(strip, at: time).compactMap { id, rect in
            guard let rest = strip.cells[id]?.frame else { return nil }
            let dx = rect.minX - rest.minX, dw = rect.width - rest.width
            return abs(dx) > 0.01 || abs(dw) > 0.01 ? "\(id) x \(dx) width \(dw)" : nil
        }.sorted()
    }

    /// The longest of the strip's three tweens under the policy of now: one motion length for any act.
    static func motionLength() throws -> CFTimeInterval {
        let lengths = [MotionTween.tabOpen, .tabClose, .tabMove].compactMap { MotionMove.tween($0, in: Motion.tabs, window: nil)?.duration }
        return try #require(lengths.max(), "SETUP: no strip tween animates on this host")
    }

    /// A key that a person holds.
    enum Held: String, CaseIterable {
        case newTab, closeTab

        /// What one press does to the model, as the app's action does: New Tab adds a tab at the end and selects
        /// it; Close Tab closes the last tab (the selection stays on the first).
        @MainActor
        func press(_ model: TabStripModel, serial: Int) {
            switch self {
            case .newTab:
                let item = TabStripOneFlightTests.tab(100 + serial)
                model.tabs.append(item)
                model.selectedID = item.id
            case .closeTab:
                model.tabs.removeLast()
            }
        }
    }

    /// A held key: press 1 starts the strip's move. Each next press, one frame after the one before, leaves no
    /// strip move on a tab and each tab at its rest place in that frame, and a closed tab is gone in that frame.
    /// After one motion length with no press, a press starts one move again.
    @Test(arguments: Held.allCases)
    func aHeldKeyShowsOneMoveAndThenNone(_ held: Held) throws {
        try Self.withStrip(tabs: held == .newTab ? 2 : 7) { model, strip, clock in
            held.press(model, serial: 1)
            strip.sync(fromModel: true)
            let first = Self.moves(strip)
            try #require(first.count > 0, "SETUP: press 1 of \(held.rawValue) started no strip move")
            #expect(first.mostOnOneKeyPath == 1, "press 1 of \(held.rawValue) left \(first.mostOnOneKeyPath) strip moves on one key path of a tab")
            for press in 2...4 {
                clock.now += Self.frame
                held.press(model, serial: press)
                strip.sync(fromModel: true)
                let moves = Self.moves(strip)
                #expect(moves.count == 0, "press \(press) of a held \(held.rawValue) left \(moves.count) strip move animations on the tabs")
                let off = Self.offRest(strip, at: clock.now)
                #expect(off.isEmpty, "press \(press) of a held \(held.rawValue): \(off.count) tabs are not at their rest place in its frame: \(off.prefix(4))")
                #expect(strip.dying.isEmpty, "press \(press) of a held \(held.rawValue): \(strip.dying.count) closed tabs still show")
                #expect(strip.cells.count == model.tabs.count, "press \(press) of a held \(held.rawValue): \(strip.cells.count) cells for \(model.tabs.count) tabs")
            }
            clock.now += try Self.motionLength() + Self.frame
            held.press(model, serial: 5)
            strip.sync(fromModel: true)
            let again = Self.moves(strip)
            #expect(again.count > 0, "one motion length after the last press, a press of \(held.rawValue) started no strip move")
            #expect(again.mostOnOneKeyPath == 1, "one motion length after the last press, a press of \(held.rawValue) left \(again.mostOnOneKeyPath) strip moves on one key path of a tab")
        }
    }

    /// The change that comes one frame into a new tab's move.
    enum Second: String, CaseIterable {
        /// Another act: a tab in the middle closes.
        case close
        /// No act: two tabs change places.
        case reorder
    }

    /// One frame into a new tab's move, a change by another act or by no act: the strip has one move and not two,
    /// and no tab jumps (each shows in that frame where it showed before the change).
    @Test(arguments: Second.allCases)
    func aChangeInAMoveLeavesOneMoveAndNoJump(_ second: Second) throws {
        try Self.withStrip(tabs: 3) { model, strip, clock in
            Held.newTab.press(model, serial: 1)
            strip.sync(fromModel: true)
            try #require(Self.moves(strip).count > 0, "SETUP: the new tab started no strip move")
            // The tabs share the row between their minimum and maximum widths, so the new tab moved each of them.
            try #require(!strip.result.isOverflowing && strip.result.standardWidth < strip.metrics.maxTabWidth - 0.5,
                         "SETUP: the tabs' widths do not follow the strip's: \(strip.result.standardWidth) pt, overflowing \(strip.result.isOverflowing)")
            clock.now += Self.frame
            let before = Self.shown(strip, at: clock.now)
            switch second {
            case .close: model.tabs.remove(at: 1)
            case .reorder: model.tabs.swapAt(1, 2)
            }
            strip.sync(fromModel: true)
            let moves = Self.moves(strip)
            try #require(moves.count > 0, "SETUP: the \(second.rawValue) moved no tab")
            #expect(moves.mostOnOneKeyPath == 1,
                    "a \(second.rawValue) one frame into a new tab's move left \(moves.mostOnOneKeyPath) strip moves on one key path of a tab")
            let after = Self.shown(strip, at: clock.now)
            for (id, was) in before {
                let now = try #require(after[id], "the tab \(id) has no cell after the \(second.rawValue)")
                #expect(abs(now.minX - was.minX) < 0.5 && abs(now.width - was.width) < 0.5,
                        "the tab \(id) jumped at the \(second.rawValue): it showed at x \(was.minX) width \(was.width), now x \(now.minX) width \(now.width)")
            }
        }
    }
}
