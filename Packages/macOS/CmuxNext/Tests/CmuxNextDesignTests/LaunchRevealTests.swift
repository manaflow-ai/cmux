import AppKit
import Testing
@testable import CmuxNextDesign

/// Launch load-in by region: held views stay clear until their own region
/// is ready, regions come in independently, and a view held after its
/// region is ready shows at once. Reduce Motion is pinned both ways: CI
/// runners have it on, the capture minis off.
@MainActor
@Suite(.serialized)
struct LaunchRevealTests {
    @Test(arguments: [false, true])
    func eachRegionComesInOnItsOwn(reduceMotion: Bool) {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = reduceMotion
        let reveal = LaunchReveal()
        let sidebar = Self.view(), tabs = Self.view(), pane = Self.view()
        reveal.hold(sidebar, until: .sidebar)
        reveal.hold(tabs, until: .tabs)
        reveal.hold(pane, until: .pane)
        #expect([sidebar, tabs, pane].allSatisfy { $0.alphaValue == 0 })
        reveal.markReady(.sidebar)
        #expect(sidebar.alphaValue == 1)
        #expect(tabs.alphaValue == 0 && pane.alphaValue == 0, "never all-or-nothing")
        reveal.markReady(.pane)
        #expect(pane.alphaValue == 1)
        #expect(tabs.alphaValue == 0)
        #expect(reveal.ready == [.sidebar, .pane])
    }

    @Test func holdingAfterReadyShowsAtOnce() {
        let reveal = LaunchReveal()
        reveal.markReady(.tabs)
        let strip = Self.view()
        strip.alphaValue = 1
        reveal.hold(strip, until: .tabs)
        #expect(strip.alphaValue == 1)
    }

    @Test func waitersRunOnceAndLateWaitersRunAtOnce() {
        let reveal = LaunchReveal()
        var runs: [String] = []
        reveal.whenReady(.pane) { runs.append("early") }
        #expect(runs.isEmpty)
        reveal.markReady(.pane)
        reveal.markReady(.pane)
        reveal.whenReady(.pane) { runs.append("late") }
        #expect(runs == ["early", "late"])
    }

    @Test func markAllReadyReleasesEveryRegion() {
        let reveal = LaunchReveal()
        let views = LaunchRegion.allCases.map { region -> NSView in
            let view = Self.view()
            reveal.hold(view, until: region)
            return view
        }
        reveal.markAllReady()
        #expect(views.allSatisfy { $0.alphaValue == 1 })
        #expect(reveal.ready == Set(LaunchRegion.allCases))
    }

    @Test func aReleasedViewIsNotKeptAlive() {
        let reveal = LaunchReveal()
        weak var gone: NSView?
        autoreleasepool {
            let view = Self.view()
            gone = view
            reveal.hold(view, until: .sidebar)
        }
        #expect(gone == nil)
        reveal.markReady(.sidebar)
    }

    @Test func theDeadlineReleasesARegionThatNeverArrives() async {
        let reveal = LaunchReveal(deadline: .milliseconds(20))
        let pane = Self.view()
        reveal.hold(pane, until: .pane)
        reveal.markReady(.sidebar)
        for _ in 0..<200 where !reveal.isReady(.pane) { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(reveal.ready == Set(LaunchRegion.allCases))
        #expect(pane.alphaValue == 1)
    }

    /// Layer-backed, as every view in a window is: its animator sets the
    /// model value at once and animates the layer.
    private static func view() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }
}
