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
}

@MainActor
private final class SimulatorVisibilityTestWindow: NSWindow {
    var reportedIsVisible = true
    var reportedIsKeyWindow = false
    var reportedOcclusionState: NSWindow.OcclusionState = []

    override var isVisible: Bool { reportedIsVisible }
    override var isKeyWindow: Bool { reportedIsKeyWindow }
    override var isMiniaturized: Bool { false }
    override var occlusionState: NSWindow.OcclusionState { reportedOcclusionState }
}
