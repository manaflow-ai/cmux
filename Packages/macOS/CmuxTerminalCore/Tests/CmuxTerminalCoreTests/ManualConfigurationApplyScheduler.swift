import Testing

@MainActor
final class ManualConfigurationApplyScheduler {
    typealias Action = @MainActor @Sendable () -> Void

    private var pending: [Action] = []

    var pendingCount: Int {
        pending.count
    }

    func schedule(_ action: @escaping Action) {
        pending.append(action)
    }

    func fireNext() {
        guard !pending.isEmpty else {
            Issue.record("Expected a scheduled configuration apply turn")
            return
        }
        pending.removeFirst()()
    }
}
