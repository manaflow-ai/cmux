import CmuxSimulator
import Foundation

extension SimulatorWorkerCoordinator {
    func performInteractiveAction(_ action: SimulatorInteractiveAction) async -> Bool {
        let succeeded: Bool
        let name: String
        let summary: String
        switch action {
        case let .gesture(events):
            succeeded = await hid?.sendGestureSequence(events) == true
            gestureStart = nil
            gestureUsesTwoFingers = false
            name = "gesture"
            summary = "events:\(events.count)"
        case let .hardwareButton(button):
            succeeded = await hid?.press(button) == true
            name = "button"
            summary = button.rawValue
        case let .rotate(orientation):
            succeeded = hid?.rotate(orientation) == true
            if succeeded { framebuffer?.setOrientation(orientation) }
            name = "rotate"
            summary = orientation.rawValue
        case let .coreAnimation(diagnostic, enabled):
            succeeded = hid?.setCoreAnimationDiagnostic(diagnostic, enabled: enabled) == true
            name = "core_animation_diagnostic"
            summary = "\(diagnostic.rawValue):\(enabled)"
        case .memoryWarning:
            succeeded = hid?.simulateMemoryWarning() == true
            name = "memory_warning"
            summary = "simulate"
        }
        if !succeeded {
            sendUnavailableFailure(action: name, detail: "The Simulator action is unavailable.")
        }
        emitAction(name, summary: summary, succeeded: succeeded)
        return succeeded
    }
}
