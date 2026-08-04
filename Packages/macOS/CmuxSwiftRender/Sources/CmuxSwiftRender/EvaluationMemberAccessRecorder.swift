/// Collects value-member reads during a single synchronous interpreter walk.
final class EvaluationMemberAccessRecorder {
    private let trackedBaseValues: [SwiftValue]
    private(set) var memberNames: Set<String> = []

    init(trackedBaseValues: [SwiftValue]) {
        self.trackedBaseValues = trackedBaseValues
    }

    func record(_ memberName: String, on baseValue: SwiftValue) {
        guard trackedBaseValues.contains(baseValue) else { return }
        memberNames.insert(memberName)
    }
}
