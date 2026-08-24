struct MobileRPCAbandonedCandidateClose: Sendable {
    let completedWithinDeadline: Bool
    let task: Task<Void, any Error>
}
