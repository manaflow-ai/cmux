/// Deterministic upper bound on text scanned by one detection phase,
/// independent of machine speed or scheduler load.
struct CmuxAgentEvaluationWorkBudget: Sendable {
    private static let maximumComparedBytes = 1 * 1024 * 1024
    private var remainingBytes = Self.maximumComparedBytes

    mutating func consume(bytes: Int) -> Bool {
        guard bytes >= 0, bytes <= remainingBytes else { return false }
        remainingBytes -= bytes
        return true
    }
}
