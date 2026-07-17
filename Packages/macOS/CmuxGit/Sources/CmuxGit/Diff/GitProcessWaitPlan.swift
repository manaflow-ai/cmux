import Foundation

struct GitProcessWaitPlan {
    let deadline: TimeInterval?

    init(
        processDeadline: TimeInterval,
        escalationDeadline: TimeInterval?,
        didSendSIGKILL: Bool,
        finalReapDeadline: TimeInterval?
    ) {
        deadline = didSendSIGKILL
            ? finalReapDeadline
            : escalationDeadline ?? processDeadline
    }
}
