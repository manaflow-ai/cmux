import CmuxSimulator

enum SimulatorWebInspectorEvent {
    case targets([SimulatorWebInspectorTarget])
    case session(SimulatorWebInspectorSessionStatus)
    case message(SimulatorWebInspectorMessageChunk)
    case failure(SimulatorWebInspectorError)
}
