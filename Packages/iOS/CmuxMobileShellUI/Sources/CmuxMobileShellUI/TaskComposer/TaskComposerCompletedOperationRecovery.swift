#if os(iOS)
import CmuxMobileShellModel

struct TaskComposerCompletedOperationRecovery: Equatable {
    enum Phase: Equatable {
        case refreshRequired
        case startAgainAvailable
    }

    enum RequestRelation: Equatable {
        case equivalent
        case different
    }

    let submittedSnapshot: MobileTaskSubmissionSnapshot
    private(set) var phase: Phase = .refreshRequired
    private(set) var requestRelation: RequestRelation = .equivalent

    var appliesToCurrentRequest: Bool {
        requestRelation == .equivalent
    }

    var blocksSubmission: Bool {
        appliesToCurrentRequest
    }

    var allowsStartAgain: Bool {
        appliesToCurrentRequest && phase == .startAgainAvailable
    }

    mutating func recordReconciliationStillMissing() {
        phase = .startAgainAvailable
    }

    mutating func markCurrentRequestDifferent() {
        requestRelation = .different
    }

    /// Returns whether an edit detached this recovery and the effective request
    /// has now returned to it, so the standard recovery banner should return.
    @discardableResult
    mutating func reconcileCurrentRequest(_ currentSnapshot: MobileTaskSubmissionSnapshot?) -> Bool {
        let wasDetachedByEdit = requestRelation == .different
        requestRelation = currentSnapshot?.isRequestEquivalent(to: submittedSnapshot) == true
            ? .equivalent
            : .different
        return wasDetachedByEdit && requestRelation == .equivalent
    }
}
#endif
