import Foundation

/// Pure transition state for one active request and one replaceable pending request.
struct FilePreviewLatestRequestState<Request: Sendable>: Sendable {
    typealias Submission = (id: Int, request: Request)

    private var nextID = 0
    private var active: Submission?
    private var pending: Submission?

    mutating func submit(_ request: Request) -> (start: Submission?, superseded: Submission?) {
        nextID &+= 1
        let submission: Submission = (id: nextID, request: request)
        guard active != nil else {
            active = submission
            return (start: submission, superseded: nil)
        }
        let superseded = pending
        pending = submission
        return (start: nil, superseded: superseded)
    }

    mutating func complete(id: Int) -> (matchedActive: Bool, shouldDeliver: Bool, next: Submission?) {
        guard active?.id == id else {
            return (matchedActive: false, shouldDeliver: false, next: nil)
        }
        let shouldDeliver = pending == nil && id == nextID
        active = nil
        let next = pending
        pending = nil
        active = next
        return (matchedActive: true, shouldDeliver: shouldDeliver, next: next)
    }

    mutating func cancel() -> (active: Submission?, pending: Submission?) {
        nextID &+= 1
        let cancellation = (active: active, pending: pending)
        pending = nil
        return cancellation
    }
}
