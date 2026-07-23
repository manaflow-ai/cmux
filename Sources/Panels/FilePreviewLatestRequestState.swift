import Foundation

/// Pure transition state for one active request and one replaceable pending request.
struct FilePreviewLatestRequestState<Request: Sendable>: Sendable {
    struct Submission: Sendable {
        let id: Int
        let request: Request
    }

    struct SubmissionTransition: Sendable {
        let start: Submission?
        let superseded: Submission?
    }

    struct Completion: Sendable {
        let shouldDeliver: Bool
        let next: Submission?
    }

    struct Cancellation: Sendable {
        let active: Submission?
        let pending: Submission?
    }

    private var nextID = 0
    private var active: Submission?
    private var pending: Submission?

    mutating func submit(_ request: Request) -> SubmissionTransition {
        nextID &+= 1
        let submission = Submission(id: nextID, request: request)
        guard active != nil else {
            active = submission
            return SubmissionTransition(start: submission, superseded: nil)
        }
        let superseded = pending
        pending = submission
        return SubmissionTransition(start: nil, superseded: superseded)
    }

    mutating func complete(id: Int) -> Completion {
        guard active?.id == id else {
            return Completion(shouldDeliver: false, next: nil)
        }
        let shouldDeliver = pending == nil && id == nextID
        active = nil
        let next = pending
        pending = nil
        active = next
        return Completion(shouldDeliver: shouldDeliver, next: next)
    }

    mutating func cancel() -> Cancellation {
        nextID &+= 1
        let cancellation = Cancellation(active: active, pending: pending)
        pending = nil
        return cancellation
    }
}
