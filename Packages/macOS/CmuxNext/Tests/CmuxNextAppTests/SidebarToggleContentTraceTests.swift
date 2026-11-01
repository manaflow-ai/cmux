import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxNextWakeups
import QuartzCore
import Testing

/// Leo, 2026-11-01: "when i toggle the sidebar on and off I STILL SEE THE ENTIRE OTHER PART OF THE
/// APP SHIFT LAYOUT FOR NO REASON AND SNAP BACK". Samples the real sidebar animation on display
/// ticks and records, per frame, the content's frame in window coordinates (what a person sees).
/// With the hold (`sidebar.slideHoldsContent`, opt-in) a toggle changes it once: to where it lands.
/// With the default (content follows the card every frame, #29894) it moves one way only, from where
/// it was to where it lands, and the landing changes nothing. Any turn back is the shift Leo saw.
/// The probe never lays out, which would repair a stale frame; it stops after a bounded recording.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarToggleContentTraceTests {
    private struct Sample {
        var sidebar: CGFloat
        var content: CGRect
        var moving: Bool
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"),
          arguments: [false, true], [true, false])
    func theContentNeverTurnsBack(startShown: Bool, holds: Bool) async throws {
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
        let savedHold = store.override(holdKey)
        store.set(holdKey, .bool(holds))
        defer {
            store.set(holdKey, savedHold)
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
        // Drain the initial observation before recording.
        try await Task.sleep(for: .milliseconds(100))
        let before = content.convert(content.bounds, to: nil)
        var samples: [Sample] = []
        let probe = FrameClient(owner: "test.sidebar-toggle-content-trace", view: root) { _ in
            samples.append(Sample(sidebar: sidebar.frame.width, content: content.convert(content.bounds, to: nil),
                                  moving: sidebar.isWidthAnimating))
            return true
        }
        probe.activate()
        defer { probe.deactivate() }
        sidebar.model.presentation = startShown ? .hidden : .shown
        sidebar.apply()
        try await Task.sleep(for: .seconds(1.5))
        probe.deactivate()

        let sliding = samples.filter { $0.moving }.count
        try #require(sliding >= 3, "the slide must animate over several display frames, not snap")
        let last = try #require(samples.last)
        try #require(!last.moving, "the slide must land within the recording")
        let after = last.content

        // Each distinct on-screen content frame in order: the start, then whatever it went through.
        var frames = [before]
        for sample in samples where !Self.same(sample.content, frames[frames.count - 1]) { frames.append(sample.content) }
        let trace = samples.map { "\(Self.r($0.sidebar)):\(Self.r($0.content.minX))+\(Self.r($0.content.width))" }
        print("TRACE sidebar-toggle startShown=\(startShown) holds=\(holds) sliding_frames=\(sliding) content_frame_changes=\(frames.count - 1) "
              + "width_changes=\(Self.changes(([before] + samples.map(\.content)).map(\.width))) "
              + "minX_changes=\(Self.changes(([before] + samples.map(\.content)).map(\.minX))) "
              + "before=\(Self.r(before.minX))+\(Self.r(before.width)) landed=\(Self.r(after.minX))+\(Self.r(after.width)) "
              + "frames(sidebar:contentMinX+contentWidth)=\(trace.joined(separator: ","))")
        if holds {
            #expect(frames.count - 1 == 1,
                    "the content's on-screen frame changed \(frames.count - 1) times in one toggle (one is to where it lands): \(frames)")
        } else {
            // Every frame's edges lie between where they were and where they land, and move only toward the landing.
            for edge in [\CGRect.minX, \CGRect.maxX, \CGRect.width] {
                let values = frames.map { $0[keyPath: edge] }
                let direction: CGFloat = after[keyPath: edge] >= before[keyPath: edge] ? 1 : -1
                #expect(zip(values, values.dropFirst()).allSatisfy { ($1 - $0) * direction >= -0.5 },
                        "the content turned back on its way to where it lands: \(values)")
            }
        }
        #expect(Self.same(frames[frames.count - 1], after))
        let settledFrom = try #require(samples.lastIndex { $0.moving }) + 1
        #expect(samples[settledFrom...].allSatisfy { Self.same($0.content, after) }, "the content moved after the slide landed")
        #expect(abs(after.width - before.width) > 100, "the toggle changed the content's width")
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.maxX - b.maxX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.maxY - b.maxY) < 0.5
    }

    private static func changes(_ values: [CGFloat]) -> Int {
        zip(values, values.dropFirst()).filter { abs($1 - $0) >= 0.5 }.count
    }

    private static func r(_ value: CGFloat) -> String { String(format: "%.1f", value) }
}
