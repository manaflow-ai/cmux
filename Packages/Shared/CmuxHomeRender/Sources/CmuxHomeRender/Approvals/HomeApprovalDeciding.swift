import Foundation
import os

/// A card from a trusted local Chief, bound to one request's content.
public struct HomeApprovalRequest: Sendable, Equatable {
    public let chief: String
    public let session: String
    public let permission: String
    public let requestJSON: String
    public init(chief: String, session: String, permission: String, requestJSON: String) {
        (self.chief, self.session, self.permission, self.requestJSON) = (chief, session, permission, requestJSON)
    }
}

public enum HomeApprovalDecision: Sendable, Equatable {
    case answered, expired, refused
}

/// Only the native app answers acpmux. The transcript records its card's answer afterward.
public protocol HomeApprovalDeciding: AnyObject, Sendable {
    @MainActor
    func decide(_ request: HomeApprovalRequest, allow: Bool, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalDecision
}

/// A single native click. Cancellation, expiry and the socket write are
/// serialized at the write-start claim on the socket queue. The lock is never
/// held across IO, so closing Home cannot block behind a socket send.
public final class HomeApprovalWriteGate: Sendable {
    private let closed = OSAllocatedUnfairLock(initialState: false)
    private let deadline: TimeInterval
    public init(deadline: TimeInterval) { self.deadline = deadline }
    public func cancel() { closed.withLock { $0 = true } }
    public func write(_ bytes: () -> Void) -> Bool {
        let claimed = closed.withLock { closed in
            guard !closed, ProcessInfo.processInfo.systemUptime <= deadline else { return false }
            closed = true
            return true
        }
        guard claimed else { return false }
        bytes()
        return true
    }
}
