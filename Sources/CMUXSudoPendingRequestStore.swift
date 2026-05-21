import Darwin
import Foundation

final class CMUXSudoPendingRequestStore {
    static let shared = CMUXSudoPendingRequestStore()
    private static let pendingTTL: TimeInterval = 11 * 60
    private static let finishedTTL: TimeInterval = 2 * 60

    struct Access: Sendable {
        let pid: pid_t
        let uid: uid_t
        let workspaceID: UUID
        let surfaceID: UUID

        func matches(peerIdentity: CMUXSocketPeerIdentity) -> Bool {
            peerIdentity.pid == pid && peerIdentity.uid == uid
        }
    }

    private enum State {
        case pending(Access, Task<Void, Never>?, Date)
        case finished(Access, CMUXSudoSocketResponse, Date)
    }

    // Synchronous v2 socket handlers cannot await an actor here. The lock keeps
    // request ownership, cancellation, and TTL pruning atomic without blocking on results.
    private let lock = NSLock()
    private var states: [String: State] = [:]

    func begin(_ requestID: String, access: Access) {
        lock.lock()
        pruneLocked(now: Date())
        states[requestID] = .pending(access, nil, Date())
        lock.unlock()
    }

    func attachTask(_ requestID: String, task: Task<Void, Never>) {
        lock.lock()
        pruneLocked(now: Date())
        switch states[requestID] {
        case .pending(let access, _, let createdAt):
            states[requestID] = .pending(access, task, createdAt)
        case .finished:
            task.cancel()
        case .none:
            task.cancel()
        }
        lock.unlock()
    }

    func finish(_ requestID: String, response: CMUXSudoSocketResponse) {
        lock.lock()
        pruneLocked(now: Date())
        switch states[requestID] {
        case .pending(let access, _, _):
            states[requestID] = .finished(access, response, Date())
        case .finished:
            break
        case .none:
            break
        }
        lock.unlock()
    }

    func state(
        for requestID: String,
        peerIdentity: CMUXSocketPeerIdentity
    ) -> CMUXSudoPendingState {
        lock.lock()
        defer { lock.unlock() }

        pruneLocked(now: Date())
        guard let state = states[requestID] else { return .missing }
        switch state {
        case .pending(let access, _, _):
            guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
            return .pending
        case .finished(let access, let response, _):
            guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
            states.removeValue(forKey: requestID)
            return .finished(response)
        }
    }

    func cancel(
        requestID: String,
        peerIdentity: CMUXSocketPeerIdentity,
        response: CMUXSudoSocketResponse
    ) -> CMUXSudoCancelState {
        lock.lock()
        defer { lock.unlock() }

        pruneLocked(now: Date())
        guard let state = states[requestID] else { return .missing }
        switch state {
        case .pending(let access, let task, _):
            guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
            task?.cancel()
            states[requestID] = .finished(access, response, Date())
            return .cancelled(response)
        case .finished(let access, let existingResponse, _):
            guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
            return .cancelled(existingResponse)
        }
    }

    private func pruneLocked(now: Date) {
        states = states.filter { _, state in
            switch state {
            case .pending(_, _, let createdAt):
                return now.timeIntervalSince(createdAt) <= Self.pendingTTL
            case .finished(_, _, let finishedAt):
                return now.timeIntervalSince(finishedAt) <= Self.finishedTTL
            }
        }
    }

#if DEBUG
    func reset() {
        lock.lock()
        for state in states.values {
            if case .pending(_, let task, _) = state {
                task?.cancel()
            }
        }
        states.removeAll()
        lock.unlock()
    }
#endif
}

enum CMUXSudoPendingState: Sendable {
    case missing
    case forbidden
    case pending
    case finished(CMUXSudoSocketResponse)
}

enum CMUXSudoCancelState: Sendable {
    case missing
    case forbidden
    case cancelled(CMUXSudoSocketResponse)
}
