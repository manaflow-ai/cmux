import CmuxSimulator
import Foundation

enum SimulatorWorkerFailure: Error, Equatable {
    case frameworkUnavailable(String)
    case privateAPIUnavailable(String)
    case deviceNotFound(String)
    case deviceNotBooted(String)
    case framebufferUnavailable(String)
    case inputUnavailable(String)
    case accessibilityUnavailable(String)
    case cameraOwnershipBusy(String)

    var processSafeValue: SimulatorFailure {
        switch self {
        case let .frameworkUnavailable(message):
            SimulatorFailure(code: "framework_unavailable", message: message, isRecoverable: false)
        case let .privateAPIUnavailable(message):
            SimulatorFailure(code: "private_api_unavailable", message: message, isRecoverable: false)
        case let .deviceNotFound(message):
            SimulatorFailure(code: "device_not_found", message: message, isRecoverable: true)
        case let .deviceNotBooted(message):
            SimulatorFailure(code: "device_not_booted", message: message, isRecoverable: true)
        case let .framebufferUnavailable(message):
            SimulatorFailure(code: "framebuffer_unavailable", message: message, isRecoverable: true)
        case let .inputUnavailable(message):
            SimulatorFailure(code: "input_unavailable", message: message, isRecoverable: true)
        case let .accessibilityUnavailable(message):
            SimulatorFailure(code: "accessibility_unavailable", message: message, isRecoverable: true)
        case let .cameraOwnershipBusy(message):
            SimulatorFailure(code: "camera_ownership_busy", message: message, isRecoverable: true)
        }
    }
}
