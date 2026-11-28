import CmuxSimulator
import Foundation

struct SimulatorWebInspectorSession {
    let identifier: UUID
    let target: SimulatorWebInspectorTarget
    let senderIdentifier: String
    var router = SimulatorWebInspectorSessionRouter()
}
