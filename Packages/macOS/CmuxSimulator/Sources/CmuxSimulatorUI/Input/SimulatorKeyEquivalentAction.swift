import CmuxSimulator

enum SimulatorKeyEquivalentAction: Equatable {
    case messages([SimulatorWorkerInbound])
}
