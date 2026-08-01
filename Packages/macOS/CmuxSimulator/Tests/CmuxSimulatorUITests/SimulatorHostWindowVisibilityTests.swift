import AppKit
import Testing

@testable import CmuxSimulatorUI

@Suite("Simulator host window visibility")
@MainActor
struct SimulatorHostWindowVisibilityTests {
    @Test("A key-window transition restores visibility when occlusion notification is missed")
    func keyWindowTransitionRestoresVisibility() throws {
        let window = SimulatorVisibilityTestWindow()
        window.reportedIsVisible = false
        let view = SimulatorHostWindowVisibilityView()
        window.contentView = view

        var observedVisibility: [Bool] = []
        view.setVisibilityHandler { observedVisibility.append($0) }
        #expect(observedVisibility.last == false)

        window.reportedIsVisible = true
        window.reportedOcclusionState = [.visible]
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )

        #expect(observedVisibility.last == true)
    }

    @Test("A key window stays renderable when WindowServer reports it occluded")
    func keyWindowOverridesStaleOcclusionState() {
        let window = SimulatorVisibilityTestWindow()
        window.reportedIsVisible = true
        window.reportedIsKeyWindow = false
        window.reportedOcclusionState = []
        let view = SimulatorHostWindowVisibilityView()
        window.contentView = view

        var observedVisibility: [Bool] = []
        view.setVisibilityHandler { observedVisibility.append($0) }
        #expect(observedVisibility.last == false)

        window.reportedIsKeyWindow = true
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )

        #expect(observedVisibility.last == true)
    }

    @Test("Resigning key status reconciles stale occlusion state")
    func resigningKeyWindowStopsVisibility() {
        let window = SimulatorVisibilityTestWindow()
        window.reportedIsVisible = true
        window.reportedIsKeyWindow = true
        window.reportedOcclusionState = []
        let view = SimulatorHostWindowVisibilityView()
        window.contentView = view

        var observedVisibility: [Bool] = []
        view.setVisibilityHandler { observedVisibility.append($0) }
        #expect(observedVisibility.last == true)

        window.reportedIsKeyWindow = false
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        #expect(observedVisibility.last == false)
    }
}
