import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
import Testing

/// An agent pane's pacer holds frames while nobody sees the pane (``AgentPaneHiddenHoldTests``). Its
/// "nobody sees" was a copy of its own (out of a window, hidden, or `occlusionState` without
/// `.visible`), so it disagreed with the rule terminals and cmux pages draw by (``WindowDrawPolicy``,
/// PATTERNS.md P10): an automation launch (`drawsWhenOccluded`) kept terminals live in an occluded
/// window while a streaming chat held every frame, and a parked workspace's chat was not hidden.
/// The pacer now reads the shared rule, and its probe hears parking changes.
@MainActor @Suite(.serialized) struct AgentPaneUnseenRuleTests {
    @MainActor private final class Calls {
        var count = 0
    }

    private final class Container: NSView, ParkingContainer {
        var isParkedOffScreen = false
    }

    /// A window never ordered in: AppKit reports it occluded on every host.
    private static func occludedWindow(with content: NSView) throws -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        try #require(window.contentView).addSubview(content)
        try #require(!window.occlusionState.contains(.visible))
        return window
    }

    private static func streamFrame(to pacer: AgentPaneFramePacer, _ calls: Calls) {
        pacer.schedule { [calls] in
            calls.count += 1
            return AgentPaneFlush(delivered: true, more: false)
        }
    }

    @Test func anAutomationLaunchDeliversToAPaneInAnOccludedWindow() throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = try Self.occludedWindow(with: pane)
        let pacer = AgentPaneFramePacer(view: pane)
        defer { pacer.stop() }
        let calls = Calls()

        Self.streamFrame(to: pacer, calls)
        #expect(calls.count == 1, "the chat held a streaming frame that a terminal in the same window would draw")
        _ = window
    }

    @Test func aParkedPaneHoldsItsFramesUntilItIsUnparked() throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        // Window occlusion plays no part here: only the parking does.
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let container = Container(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let pane = NSView(frame: container.bounds)
        container.addSubview(pane)
        let window = try Self.occludedWindow(with: container)
        let pacer = AgentPaneFramePacer(view: pane)
        defer { pacer.stop() }
        let calls = Calls()

        container.isParkedOffScreen = true
        container.notifyParkingChange()
        Self.streamFrame(to: pacer, calls)
        #expect(calls.count == 0, "a parked workspace's chat got a streaming frame")
        #expect(pacer.held)

        container.isParkedOffScreen = false
        container.notifyParkingChange()
        #expect(calls.count == 1, "the held frames did not go when the pane was unparked")
        _ = window
    }
}
