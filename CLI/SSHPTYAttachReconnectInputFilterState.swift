struct SSHPTYAttachReconnectInputFilterState: Sendable {
    let isFiltering: Bool
    let pending: [UInt8]
    let deadlineReached: @Sendable () -> Bool
    let remainingDeadlineMilliseconds: @Sendable () -> Int64?
}
