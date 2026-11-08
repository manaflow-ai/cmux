import CmuxSimulator

struct SimulatorPendingWebInspectorResponse {
    let continuation: CheckedContinuation<
        Result<SimulatorWebInspectorCommandResponse, SimulatorFailure>,
        Never
    >
    let timeoutTask: Task<Void, Never>
    var sendTask: Task<Void, Never>?
}
