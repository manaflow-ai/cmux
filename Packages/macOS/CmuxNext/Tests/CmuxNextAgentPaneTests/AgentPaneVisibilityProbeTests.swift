import AppKit
import Testing
@testable import CmuxNextAgentPane

/// Every agent pane in a window holds an ``AgentPaneVisibilityProbe`` that follows its window's
/// occlusion. The window's occlusion notice is observed once for all of its panes
/// (plans/cmux-next/PATTERNS.md P3, targeted observation): a window with more agent panes registers
/// no more observers, and each pane still hears the window's occlusion change.
@MainActor
@Suite
struct AgentPaneVisibilityProbeTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        return window
    }

    @Test func morePanesInOneWindowRegisterNoMoreOcclusionObservers() throws {
        _ = NSApplication.shared
        let window = Self.window()
        let content = try #require(window.contentView)
        let center = CountingCenter()
        let heard = Heard(probes: 2)
        let first = AgentPaneVisibilityProbe(center: center)
        first.onChange = { heard.counts[0] += 1 }
        content.addSubview(first)
        let onePane = center.registrations
        let second = AgentPaneVisibilityProbe(center: center)
        second.onChange = { heard.counts[1] += 1 }
        content.addSubview(second)
        #expect(center.registrations == onePane)
        // Each probe reported once when it moved to the window; the notice reaches both again.
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(heard.counts == [2, 2])
    }

    /// A probe that left its window hears none of that window's occlusion changes.
    @Test func aProbeThatLeftItsWindowHearsNothing() throws {
        _ = NSApplication.shared
        let window = Self.window()
        let content = try #require(window.contentView)
        let center = NotificationCenter()
        let heard = Heard(probes: 1)
        let probe = AgentPaneVisibilityProbe(center: center)
        content.addSubview(probe)
        probe.onChange = { heard.counts[0] += 1 }
        probe.removeFromSuperview()
        let afterLeaving = heard.counts
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(heard.counts == afterLeaving)
    }
}

/// How many reports each probe made (a main-actor reference, so the probes' main-actor callbacks can count).
private final class Heard {
    var counts: [Int]

    init(probes: Int) {
        counts = Array(repeating: 0, count: probes)
    }
}

/// A center that counts observer registrations. The tests register and post on the main actor only.
private nonisolated final class CountingCenter: NotificationCenter, @unchecked Sendable {
    private(set) var registrations = 0

    override func addObserver(
        forName name: NSNotification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        registrations += 1
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
}
