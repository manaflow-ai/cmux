import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxNextWakeups
import QuartzCore
import Testing

/// Leo 2026-11-05: "If we had a proper animation system, everything moves as one, as one." The sidebar's slide steps on
/// the window's motion clock, the one the panes' springs step on, so each of its frames and theirs land in the same
/// frame; on an AppKit animation timer of its own the two drifted apart.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarSlideClockTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"), arguments: [false, true])
    func theSlideStepsOnTheWindowsMotionClock(startShown: Bool) async throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = (design.animationsEnabled, design.disabledAnimationCategories, design.animationSpeed, design.calmMode,
                     Motion.reduceMotionOverride)
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        design.animationSpeed = .normal
        design.calmMode = .off
        Motion.reduceMotionOverride = false
        defer {
            design.animationsEnabled = saved.0
            design.disabledAnimationCategories = saved.1
            design.animationSpeed = saved.2
            design.calmMode = saved.3
            Motion.reduceMotionOverride = saved.4
        }

        let sidebar = SidebarContainerView(model: SidebarModel())
        sidebar.restore(width: 300, presentation: startShown ? .shown : .hidden)
        let root = WindowRootView(sidebar: sidebar)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentView = root
        let content = NSView()
        root.show(content)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()
        try #require(window.screen != nil && Motion.canAnimate(in: sidebar), "needs an awake GUI display")
        try #require(Motion.sidebar.duration(.appear) > 0 && Motion.sidebar.duration(.disappear) > 0)
        try await Task.sleep(for: .milliseconds(100))

        let clock = MotionClock.forWindow(window)
        var onClock = 0, frames = 0
        let probe = FrameClient(owner: "test.sidebar-slide-clock", view: root) { _ in
            guard sidebar.isWidthAnimating else { return true }
            frames += 1
            if clock.running.contains("sidebar.width") { onClock += 1 }
            return true
        }
        probe.activate()
        defer { probe.deactivate() }
        sidebar.model.presentation = startShown ? .hidden : .shown
        sidebar.apply()
        try await Task.sleep(for: .seconds(1))
        probe.deactivate()
        try #require(frames >= 6, "the slide must run over several display frames (\(frames))")
        #expect(onClock >= frames - 1, "the slide was off the window's motion clock on \(frames - onClock) of \(frames) frames")
        #expect(!sidebar.isWidthAnimating && !clock.running.contains("sidebar.width"), "the slide did not settle off the clock")
    }
}
