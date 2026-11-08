/// The classified liveness result for a recorded restorable-agent process identifier.
public struct RestorableAgentProcessObservation: Equatable, Sendable {
    /// The live process identifier when inspection matched the recorded agent generation.
    public let processID: Int?
    /// The liveness classification derived from the recorded identifier and current inspection.
    public let liveness: RestorableAgentProcessLiveness

    /// Classifies a recorded process identifier using caller-provided process inspection.
    ///
    /// - Parameters:
    ///   - recordedProcessID: The process identifier saved by the agent hook.
    ///   - processMatch: Returns whether a valid identifier still represents the expected agent generation.
    public init(
        recordedProcessID: Int?,
        processMatch: (Int) -> RestorableAgentProcessMatch
    ) {
        guard let recordedProcessID else {
            processID = nil
            liveness = .unknown
            return
        }
        guard recordedProcessID > 0, recordedProcessID <= Int(Int32.max) else {
            processID = nil
            liveness = .exited
            return
        }
        switch processMatch(recordedProcessID) {
        case .matches:
            processID = recordedProcessID
            liveness = .running
        case .mismatches:
            processID = nil
            liveness = .exited
        case .unknown:
            processID = nil
            liveness = .unknown
        }
    }
}
