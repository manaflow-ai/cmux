import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Close case A (Lawrence cmux-ad m49, "A: animate the tab strip"): while a closed tab slides out, the observation's echo
/// of the close (the same model the strip already shows) walks no row: no layout, no frame pass, no occlusion pass.
/// Before, a closing tab made the strip not at rest, so every echo during the 200 ms slide ran a full sync and frame
/// pass. Prints `TAB-STRIP-CLOSE n=<count> close=<µs> echo=<µs>`: the close's own sync (the strip's part of the Cmd-W
/// key turn, budget < 10 ms) and one echo during the slide. Timing is printed, not gated.
///
/// The echo check needs the strip in a window, and the close slides only in a window on a screen
/// (`Motion.canAnimate`), so this needs a display worker (`--display`); without a screen it is skipped.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .closesItsWindows)
struct TabCloseEchoWorkTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    @Test(.enabled("the strip animates only in a window on a screen") { await Self.hasDisplay() }, arguments: [10, 30])
    func anEchoDuringACloseWalksNoRow(_ count: Int) throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let enabledAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newTab)
        defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
        try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")

        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab number \($0)") }
        let model = TabStripModel(tabs: items, selectedID: items.first?.id)
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1400, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        strip.frame = NSRect(x: 0, y: 0, width: 1400, height: 40)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        try #require(window.screen != nil, "SETUP: the strip's window is on no screen")
        strip.syncFromModel()
        CATransaction.flush()
        try #require(Motion.canAnimate(in: strip), "SETUP: the strip's window cannot animate on this host")

        model.tabs.remove(at: 1)
        let closeStart = CACurrentMediaTime()
        strip.syncFromModel()
        let close = CACurrentMediaTime() - closeStart
        try #require(strip.dying.contains(TabID("t1")), "SETUP: the close did not slide")

        let before = strip.rowPasses
        let echoes = 20
        let echoStart = CACurrentMediaTime()
        for _ in 0..<echoes { strip.syncFromModel() }
        let echo = (CACurrentMediaTime() - echoStart) / Double(echoes)
        print(String(format: "TAB-STRIP-CLOSE n=%d close=%.1fus echo=%.1fus passes=%@", count, close * 1e6, echo * 1e6,
                     "\(before) -> \(strip.rowPasses)"))
        #expect(strip.rowPasses == before, "\(echoes) echoes of the close walked the row: \(before) -> \(strip.rowPasses)")
        #expect(strip.dying.contains(TabID("t1")), "an echo ended the close")
    }
}
