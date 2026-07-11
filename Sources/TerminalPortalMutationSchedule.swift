struct TerminalPortalMutationSchedule {
    let drain: Task<Void, Never>
    let candidateCleanupTask: Task<Void, Never>?

    var value: Void {
        get async {
            await drain.value
        }
    }
}
