import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// FRAME OWNER REFACTOR S1B, pixel-perfect's #34380 film finding 4: with the PR, a single column key's spring frames ran
/// up to two window layout passes each (debug.frames window_layouts_per_frame 1.62-2.00 against base 0.81-1.00).
///
/// Each frame here runs what one display frame runs, in its order: the frame tick (`advanceFrame`), the window's
/// display-cycle layout pass (`NSWindow.layoutIfNeeded`), the work after the commit (`afterCommit`) and the main turns
/// queued by then. A view that needs layout after all that costs the window a second pass before the next frame. The
/// rule: a column key's spring frame needs at most one window layout pass, and after it no view of the window needs
/// layout. A miss names the views that still need it (class and superview chain).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeWindowLayoutPassesTests {
    typealias Ground = PaneGroundCoversPaneTests

    /// Every view under `view` that needs layout, as "Class < Superclass chain".
    static func needingLayout(_ view: NSView, into found: inout [String]) {
        if view.needsLayout {
            var chain: [String] = [], up = view.superview
            while let next = up, chain.count < 5 { chain.append(String(describing: type(of: next))); up = next.superview }
            found.append("\(type(of: view)) < \(chain.joined(separator: " < "))")
        }
        for sub in view.subviews { needingLayout(sub, into: &found) }
    }

    /// One window layout pass the way the display cycle runs it; 1 when it laid out a view.
    static func windowPass(_ window: NSWindow) -> Int {
        let before = LayoutPassGuard.shared.windowLayoutPasses
        window.layoutIfNeeded()
        return LayoutPassGuard.shared.windowLayoutPasses - before
    }

    /// The main turns queued by now (blocks, main-queue work, main-actor tasks), with no wait.
    static func drainMainTurns() {
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date()) }
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func aColumnKeysSpringFrameNeedsOneWindowLayoutPass(reverse: Bool, shell: Bool) throws {
        LayoutPassGuard.shared.install()
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        if shell {
            // The app's window class (its layout pass runs the overlay layer's work), titled as the app's is.
            let shellWindow = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                          backing: .buffered, defer: false)
            shellWindow.isReleasedWhenClosed = false
            rig.window.contentView = nil
            shellWindow.contentView = rig.root
            rig.root.layoutSubtreeIfNeeded()
            rig.root.driver.isManual = true
        }
        defer { if shell { rig.root.window?.close() } }
        guard let window = rig.root.window, let content = window.contentView else { throw CancellationError() }
        // At rest first: the rig's own setup passes and turns.
        Self.drainMainTurns()
        _ = Self.windowPass(window)
        var extra: [String] = [], keyTurn: [Int] = [], frames = 0, firstPasses: [Int] = []
        let keys: [LayoutDirection] = reverse ? [.right, .left, .right] : [.left, .right, .left]
        for (index, key) in keys.enumerated() {
            #expect(PaneResize.press("p2", key, model: rig.model, view: rig.root))
            var marked: [String] = []
            Self.needingLayout(content, into: &marked)
            if !marked.isEmpty { print("S1B-WINDOW-LAYOUT shell \(shell) press \(index): the key's turn marked \(marked.prefix(8))") }
            // The key's own turn: the display cycle after the event.
            keyTurn.append(Self.windowPass(window))
            Self.drainMainTurns()
            var moving = true, frame = 0
            while moving, frame < 240 {
                moving = rig.root.advanceFrame(1.0 / 120)
                let first = Self.windowPass(window)
                if frame == 0 { firstPasses.append(first) }
                let work = rig.afterCommit
                rig.afterCommit.removeAll()
                for item in work { item() }
                Self.drainMainTurns()
                var needs: [String] = []
                Self.needingLayout(content, into: &needs)
                let second = Self.windowPass(window)
                if second > 0 || !needs.isEmpty {
                    extra.append("press \(index) frame \(frame) (moving \(moving)): first pass \(first), second pass \(second), needs layout: \(needs.prefix(4))")
                }
                frame += 1
                frames += 1
            }
        }
        print("S1B-WINDOW-LAYOUT shell \(shell) reverse \(reverse) key turn passes \(keyTurn), first frame passes \(firstPasses), frames \(frames), extra \(extra.count)")
        for line in extra.prefix(40) { print("S1B-WINDOW-LAYOUT shell \(shell) \(line)") }
        #expect(extra.isEmpty, "\(extra.count) of \(frames) spring frames needed a second window layout pass: \(extra.prefix(4))")
    }
}
