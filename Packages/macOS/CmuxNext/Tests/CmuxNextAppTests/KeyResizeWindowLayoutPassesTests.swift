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

    /// One window layout pass the way the display cycle runs it, for the window and then its child windows (the overlay
    /// host panel); the number of windows it laid out a view in.
    static func windowPass(_ window: NSWindow) -> Int {
        let before = LayoutPassGuard.shared.windowLayoutPasses
        window.layoutIfNeeded()
        for child in window.childWindows ?? [] { child.layoutIfNeeded() }
        return LayoutPassGuard.shared.windowLayoutPasses - before
    }

    /// Views needing layout in `window`'s child windows (the overlay host panel), prefixed with the window class.
    static func childNeeds(_ window: NSWindow) -> [String] {
        var found: [String] = []
        for child in window.childWindows ?? [] {
            guard let frame = child.contentView?.superview ?? child.contentView else { continue }
            var here: [String] = []
            needingLayout(frame, into: &here)
            found += here.map { "\(type(of: child)): \($0)" }
        }
        return found
    }

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Page mode as in the app with a Chromium page: a shown ShellWindow with a page child window, so the layout's
    /// overlay plane lives in the overlay host panel (`WindowOverlayLayer.placement == .overlayWindow`). Each spring frame:
    /// at most one layout pass per window, and after it no view of the panel needs layout.
    @Test(.enabled("page mode needs a window on screen") { await Self.hasDisplay() }, arguments: [false, true])
    func aColumnKeysSpringFrameInPageModeLaysTheOverlayPanelOutOnce(reverse: Bool) throws {
        LayoutPassGuard.shared.install()
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        let shell = ShellWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                backing: .buffered, defer: false)
        shell.isReleasedWhenClosed = false
        rig.window.contentView = nil
        shell.contentView = rig.root
        shell.orderFrontRegardless()
        rig.root.layoutSubtreeIfNeeded()
        rig.root.driver.isManual = true
        let page = NSWindow(contentRect: shell.frame.insetBy(dx: 300, dy: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        shell.addChildWindow(page, ordered: .above)
        shell.overlayLayer.evaluate()
        defer {
            shell.removeChildWindow(page)
            page.close()
            shell.close()
        }
        try #require(shell.overlayLayer.placement == .overlayWindow, "the page did not put the window in page mode")
        Self.drainMainTurns()
        _ = Self.windowPass(shell)
        let keys: [LayoutDirection] = reverse ? [.right, .left, .right] : [.left, .right, .left]
        var extra: [String] = [], frames = 0, passes: [Int] = []
        for (index, key) in keys.enumerated() {
            #expect(PaneResize.press("p2", key, model: rig.model, view: rig.root))
            passes.append(Self.windowPass(shell))
            Self.drainMainTurns()
            var moving = true, frame = 0
            while moving, frame < 240 {
                moving = rig.root.advanceFrame(1.0 / 120)
                let first = Self.windowPass(shell)
                let work = rig.afterCommit
                rig.afterCommit.removeAll()
                for item in work { item() }
                Self.drainMainTurns()
                let needs = Self.childNeeds(shell)
                let second = Self.windowPass(shell)
                if frame < 3 || second > 0 || !needs.isEmpty {
                    let line = "press \(index) frame \(frame) (moving \(moving)): windows laid out \(first), again \(second), panel needs \(needs.prefix(4))"
                    if second > 0 || !needs.isEmpty { extra.append(line) }
                    print("S1B-WINDOW-LAYOUT page \(line)")
                }
                frame += 1
                frames += 1
            }
        }
        print("S1B-WINDOW-LAYOUT page reverse \(reverse) key turn windows \(passes), frames \(frames), extra \(extra.count)")
        #expect(extra.isEmpty, "\(extra.count) of \(frames) spring frames laid a window out again: \(extra.prefix(4))")
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
