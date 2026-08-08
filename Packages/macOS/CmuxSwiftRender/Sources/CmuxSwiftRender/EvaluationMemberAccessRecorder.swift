/// Collects value-member reads during a single synchronous interpreter walk.
final class EvaluationMemberAccessRecorder {
    private let trackedBaseValue: SwiftValue?
    private(set) var memberNames: Set<String> = []

    /// Creates a recorder for one optional base value.
    init(trackedBaseValue: SwiftValue?) {
        self.trackedBaseValue = trackedBaseValue
    }

    /// Records a direct member read only when its base matches the tracked value.
    func record(_ memberName: String, on baseValue: SwiftValue) {
        guard let trackedBaseValue, baseValue == trackedBaseValue else {
            return
        }
        memberNames.insert(memberName)
    }
}
