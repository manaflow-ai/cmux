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

    override var isVisible: Bool { reportedIsVisible }
    override var isMiniaturized: Bool { false }
    override var occlusionState: NSWindow.OcclusionState {
        reportedIsVisible ? [.visible] : []
    }
}
