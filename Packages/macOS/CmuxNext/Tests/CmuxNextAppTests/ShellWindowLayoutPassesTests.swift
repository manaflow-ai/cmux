import AppKit
@testable import CmuxNextApp
import CmuxNextWakeups
import Testing

/// Views that follow an ancestor's move (remote page popups, the Home transcript's pixel
/// snap) read their place after the window's layout pass, not after each event. The shell window tells its
/// `WindowLayoutPasses` once per outermost pass, and a window update (each key) tells it nothing.
@MainActor @Suite(.serialized) struct ShellWindowLayoutPassesTests {
    @MainActor private final class Count {
        var value = 0
    }

    @Test func theOutermostLayoutPassTellsItsObserversOnceAndAWindowUpdateNever() {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let passes = Count()
        let watch = window.layoutPasses.observe(owner: "test") { passes.value += 1 }
        defer { watch.cancel() }
        let before = passes.value

        // AppKit posts didUpdate once per event of the window: the stand-in for 100 keys.
        for _ in 0..<100 { window.update() }
        #expect(passes.value == before, "a window update told the layout pass observers")

        window.contentView?.needsLayout = true
        window.layoutIfNeeded()
        #expect(passes.value == before + 1, "one layout pass told its observers \(passes.value - before) times")

        watch.cancel()
        window.contentView?.needsLayout = true
        window.layoutIfNeeded()
        #expect(passes.value == before + 1, "a cancelled observer was told a layout pass")
        #expect(window.layoutPasses.observerCount == 0)
    }
}
