struct ApplicationSurfacePendingStop: Equatable {
    static let maximumFailedAttemptCount = 3

    let sessionID: String
    let helperIdentity: AgentPIDProcessIdentity
    let failedAttemptCount: Int
    var helperRestartAttempted: Bool = false
}
