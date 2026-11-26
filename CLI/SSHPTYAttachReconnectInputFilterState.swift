struct SSHPTYAttachReconnectInputFilterState: Sendable {
    let isFiltering: Bool
    let deadlineReached: @Sendable () -> Bool
    let remainingDeadlineMilliseconds: @Sendable () -> Int64?
}
