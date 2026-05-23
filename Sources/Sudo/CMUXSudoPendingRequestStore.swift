import Darwin
import Foundation

final class CMUXSudoPendingRequestStore {
    static let shared = CMUXSudoPendingRequestStore()
    private static let pendingTTL: TimeInterval = 11 * 60
    private static let finishedTTL: TimeInterval = 2 * 60

    struct Access: Sendable {
        let pid: pid_t
        let uid: uid_t
        let processStartTime: UInt64
        let workspaceID: UUID
        let surfaceID: UUID

        func matches(peerIdentity: CMUXSocketPeerIdentity) -> Bool {
            peerIdentity.pid == pid
                && peerIdentity.uid == uid
                && peerIdentity.processStartTime == processStartTime
        }
    }

    private enum State {
        case pending(Access, Task<Void, Never>?, Date)
        case finished(Access, CMUXSudoSocketResponse, Date)
    }

    // Synchronous v2 socket handlers cannot await an actor here. The condition
    // keeps request ownership, cancellation, TTL pruning, and result waits atomic.
    private let condition = NSCondition()
    private var states: [String: State] = [:]

    func begin(_ requestID: String, access: Access) -> Bool {
        condition.lock()
        defer { condition.unlock() }

        pruneLocked(now: Date())
        guard states[requestID] == nil else { return false }
        states[requestID] = .pending(access, nil, Date())
        return true
    }

    func attachTask(_ requestID: String, task: Task<Void, Never>) {
        condition.lock()
        pruneLocked(now: Date())
        switch states[requestID] {
        case .pending(let access, let existingTask, let createdAt):
            existingTask?.cancel()
            states[requestID] = .pending(access, task, createdAt)
        case .finished:
            task.cancel()
        case .none:
            task.cancel()
        }
        condition.unlock()
    }

    func finish(_ requestID: String, response: CMUXSudoSocketResponse) {
        condition.lock()
        pruneLocked(now: Date())
        switch states[requestID] {
        case .pending(let access, _, _):
            states[requestID] = .finished(access, response, Date())
            condition.broadcast()
        case .finished:
            break
        case .none:
            break
        }
        condition.unlock()
    }

    func state(
        for requestID: String,
        peerIdentity: CMUXSocketPeerIdentity,
        waitUntil deadline: Date? = nil
    ) -> CMUXSudoPendingState {
        condition.lock()
        defer { condition.unlock() }

        while true {
            pruneLocked(now: Date())
            guard let state = states[requestID] else { return .missing }
            switch state {
            case .pending(let access, _, _):
                guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
                guard let deadline, Date() < deadline else { return .pending }
                _ = condition.wait(until: deadline)
            case .finished(let access, let response, _):
                guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
                states.removeValue(forKey: requestID)
                return .finished(response)
            }
        }
    }

    func cancel(
        requestID: String,
        peerIdentity: CMUXSocketPeerIdentity,
        response: CMUXSudoSocketResponse
    ) -> CMUXSudoCancelState {
        condition.lock()
        defer { condition.unlock() }

        pruneLocked(now: Date())
        guard let state = states[requestID] else { return .missing }
        switch state {
        case .pending(let access, let task, _):
            guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
            task?.cancel()
            condition.broadcast()
            return .cancelled(response)
        case .finished(let access, let existingResponse, _):
            guard access.matches(peerIdentity: peerIdentity) else { return .forbidden }
            return .finished(existingResponse)
        }
    }

    private func pruneLocked(now: Date) {
        for state in states.values {
            guard case .pending(_, let task, let createdAt) = state,
                  now.timeIntervalSince(createdAt) > Self.pendingTTL else {
                continue
            }
            task?.cancel()
        }
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
        condition.lock()
        for state in states.values {
            if case .pending(_, let task, _) = state {
                task?.cancel()
            }
        }
        states.removeAll()
        condition.unlock()
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
    case finished(CMUXSudoSocketResponse)
}
