import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Remote daemon RPC support types
final class WorkspaceRemoteDaemonPendingCallRegistry {
    final class PendingCall {
        let id: Int
        fileprivate let semaphore = DispatchSemaphore(value: 0)
        fileprivate var response: [String: Any]?
        fileprivate var failureMessage: String?

        fileprivate init(id: Int) {
            self.id = id
        }
    }

    enum WaitOutcome {
        case response([String: Any])
        case failure(String)
        case missing
        case timedOut
    }

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.pending.\(UUID().uuidString)")
    private var nextRequestID = 1
    private var pendingCalls: [Int: PendingCall] = [:]

    func reset() {
        queue.sync {
            nextRequestID = 1
            pendingCalls.removeAll(keepingCapacity: false)
        }
    }

    func register() -> PendingCall {
        queue.sync {
            let call = PendingCall(id: nextRequestID)
            nextRequestID += 1
            pendingCalls[call.id] = call
            return call
        }
    }

    @discardableResult
    func resolve(id: Int, payload: [String: Any]) -> Bool {
        queue.sync {
            guard let pendingCall = pendingCalls[id] else { return false }
            pendingCall.response = payload
            pendingCall.semaphore.signal()
            return true
        }
    }

    func failAll(_ message: String) {
        queue.sync {
            let calls = Array(pendingCalls.values)
            for call in calls {
                guard call.response == nil, call.failureMessage == nil else { continue }
                call.failureMessage = message
                call.semaphore.signal()
            }
        }
    }

    func remove(_ call: PendingCall) {
        _ = queue.sync {
            pendingCalls.removeValue(forKey: call.id)
        }
    }

    func wait(for call: PendingCall, timeout: TimeInterval) -> WaitOutcome {
        if call.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            _ = queue.sync {
                pendingCalls.removeValue(forKey: call.id)
            }
            // A response can win the race immediately before timeout cleanup removes the call.
            // Drain any late signal so DispatchSemaphore is not deallocated with a positive count.
            _ = call.semaphore.wait(timeout: .now())
            return .timedOut
        }

        return queue.sync {
            guard let pendingCall = pendingCalls.removeValue(forKey: call.id) else {
                return .missing
            }
            if let failure = pendingCall.failureMessage {
                return .failure(failure)
            }
            guard let response = pendingCall.response else {
                return .missing
            }
            return .response(response)
        }
    }
}

enum WorkspaceRemotePTYBridgeEvent {
    case ready
    case data(Data)
    case exit
    case error(String)
}

struct WorkspaceRemotePTYBridgeAttachment {
    let attachmentID: String
    let token: String
}

protocol WorkspaceRemotePTYBridgeRPCClient: AnyObject {
    func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (WorkspaceRemotePTYBridgeEvent) -> Void
    ) throws -> WorkspaceRemotePTYBridgeAttachment

    func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        completion: @escaping (Error?) -> Void
    )
    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String)
}

nonisolated func remoteDaemonMissingRequiredCapabilitiesMessage(_ missingCapabilities: [String]) -> String {
    let missing = Set(missingCapabilities)
    if missing.contains(WorkspaceRemoteDaemonRPCClient.requiredPTYSessionCapability) ||
        missing.contains(WorkspaceRemoteDaemonRPCClient.requiredPTYSessionTokenCapability) ||
        missing.contains(WorkspaceRemoteDaemonRPCClient.requiredPTYPersistentDaemonCapability) ||
        missing.contains(WorkspaceRemoteDaemonRPCClient.requiredPTYWriteNotificationCapability) {
        return String(
            localized: "remoteDaemon.error.missingPersistentPTYCapability",
            defaultValue: "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        )
    }
    return String(
        localized: "remoteDaemon.error.missingRequiredFunctionality",
        defaultValue: "remote daemon is missing required functionality; reconnect the remote workspace to update cmux"
    )
}

extension WorkspaceRemoteDaemonRPCClient: WorkspaceRemotePTYBridgeRPCClient {
    func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (WorkspaceRemotePTYBridgeEvent) -> Void
    ) throws -> WorkspaceRemotePTYBridgeAttachment {
        try attachPTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            cols: cols,
            rows: rows,
            command: command,
            requireExisting: requireExisting,
            queue: queue
        ) { event in
            switch event {
            case .ready:
                onEvent(.ready)
            case .data(let data):
                onEvent(.data(data))
            case .exit:
                onEvent(.exit)
            case .error(let detail):
                onEvent(.error(detail))
            }
        }
    }
}

