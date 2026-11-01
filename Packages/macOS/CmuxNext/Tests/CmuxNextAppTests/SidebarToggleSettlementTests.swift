import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxNextWakeups
import QuartzCore
import Testing

/// Leo: the left sidebar "snaps and jitters after it overshoots and needs to correct itself".
/// Sample the real animation without laying out from the probe: that would repair a stale frame.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarToggleSettlementTests {
    private struct Sample {
        var leg: Int
        var width: CGFloat
        var drawnWidth: CGFloat
        var constraint: CGFloat
        var card: CGRect
        var content: CGRect
        var moving: Bool
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"),
          arguments: [false, true], [false, true])
    func toggleHasNoOvershootOrCorrectionFrame(startShown: Bool, reverse: Bool) async throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let saved = (design.animationsEnabled, design.disabledAnimationCategories,
                     design.animationSpeed, design.calmMode, Motion.reduceMotionOverride)
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        design.animationSpeed = .normal
        design.calmMode = .off
        Motion.reduceMotionOverride = false
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(SidebarTunables.all)
        let holdKey = SidebarTunables.slideHoldsContent.key
        let collapseKey = SidebarTunables.collapseMotion.key
        let savedHold = store.override(holdKey), savedCollapse = store.override(collapseKey)
        store.set(holdKey, nil)
        store.set(collapseKey, nil)
        defer {
            store.set(holdKey, savedHold)
            store.set(collapseKey, savedCollapse)
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
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentView = root
        let content = NSView()
        root.show(content)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        content.frame = root.contentHost.bounds
        CATransaction.flush()
        try #require(window.screen != nil && Motion.canAnimate(in: sidebar), "needs an awake GUI display")
        try #require(Motion.sidebar.duration(.appear) > 0 && Motion.sidebar.duration(.disappear) > 0)
        // Drain the initial observation before choosing the endpoints.
        try await Task.sleep(for: .milliseconds(100))
        let start = sidebar.frame.width
        let target: CGFloat = startShown ? 0 : sidebar.model.width
        try #require(abs(target - start) > 100)
        let layer = try #require(sidebar.layer)
        var samples: [Sample] = []
        var leg = 0
        var intermediate = 0
        var reverseFrom: CGFloat?
        let probe = FrameClient(owner: "test.sidebar-toggle-settlement", view: root) { _ in
            let width = sidebar.frame.width
            samples.append(Sample(leg: leg, width: width,
                                  drawnWidth: (layer.presentation() ?? layer).bounds.width,
                                  constraint: sidebar.widthConstraint.constant,
                                  card: root.contentHost.frame, content: content.frame,
                                  moving: sidebar.isWidthAnimating))
            if leg == 0, width > min(start, target) + 1, width < max(start, target) - 1 {
                intermediate += 1
                if reverse && intermediate == 3 {
                    reverseFrom = width
                    leg = 1
                    sidebar.model.presentation = startShown ? .shown : .hidden
                    sidebar.apply()
                }
            }
            return true
        }
        probe.activate()
        defer { probe.deactivate() }
        sidebar.model.presentation = startShown ? .hidden : .shown
        sidebar.apply()
        // A bounded recording includes several display frames after both possible legs finish.
        try await Task.sleep(for: .seconds(2))
        probe.deactivate()
        try #require(samples.count >= 12, "the display-frame probe must actually run")
        try #require(intermediate >= 3, "an instant snap cannot pass as a smooth transition")
        if reverse { try #require(reverseFrom != nil, "the reversal must happen mid-flight") }

        let tolerance: CGFloat = 0.75
        for sample in samples {
            let from = sample.leg == 0 ? start : (reverseFrom ?? start)
            let to = sample.leg == 0 ? target : start
            #expect(sample.width >= min(from, to) - tolerance && sample.width <= max(from, to) + tolerance)
            // At a reversal the compositor can still show the previous display frame. The global
            // endpoints remain hard bounds; per-leg monotonicity is checked below.
            #expect(sample.drawnWidth >= min(start, target) - tolerance && sample.drawnWidth <= max(start, target) + tolerance)
            #expect(abs(sample.content.width - sample.card.width) <= tolerance,
                    "content width \(sample.content.width) must follow card \(sample.card.width)")
            #expect(abs(sample.content.minX) <= tolerance && abs(sample.content.minY) <= tolerance)
            #expect(abs(sample.content.height - sample.card.height) <= tolerance)
        }
        for (before, after) in zip(samples, samples.dropFirst()) where before.leg == after.leg {
            let from = after.leg == 0 ? start : (reverseFrom ?? start)
            let to = after.leg == 0 ? target : start
            let direction: CGFloat = to > from ? 1 : -1
            #expect((after.width - before.width) * direction >= -tolerance, "model width turned away from its target")
            #expect((after.drawnWidth - before.drawnWidth) * direction >= -tolerance, "displayed width turned away from its target")
        }
        let finalLeg = reverse ? 1 : 0
        let finalTarget = reverse ? start : target
        let settled = samples.filter { $0.leg == finalLeg && !$0.moving }
        try #require(settled.count >= 6, "must sample after settlement, not only during motion")
        let first = try #require(settled.first)
        for sample in settled {
            #expect(abs(sample.width - finalTarget) <= tolerance)
            #expect(abs(sample.drawnWidth - finalTarget) <= tolerance)
            #expect(abs(sample.constraint - finalTarget) <= tolerance)
            #expect(sample.card == first.card && sample.content == first.content,
                    "geometry changed after the motion reported settlement")
        }
    }
}
