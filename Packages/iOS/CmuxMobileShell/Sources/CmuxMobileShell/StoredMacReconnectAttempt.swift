/// The retirement decision for one reconnect, independent of task cancellation delivery.
@MainActor
final class StoredMacReconnectAttempt {
    let generation: Int
    private(set) var retirement: StoredMacReconnectOutcome?
    var deadlineTask: Task<MobileShellComposite.DeadlineRaceOutcome<StoredMacReconnectOutcome>, Never>?

    init(generation: Int) { self.generation = generation }

    func retire(with outcome: StoredMacReconnectOutcome) {
        guard retirement == nil else { return }
        retirement = outcome
        deadlineTask?.cancel()
    }
}
