/// Collects value-member reads during a single synchronous interpreter walk.
final class EvaluationMemberAccessRecorder {
    private(set) var memberNames: Set<String> = []

    func record(_ memberName: String) {
        memberNames.insert(memberName)
    }
}
