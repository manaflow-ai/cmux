import CmuxControlSocket
import Dispatch
import Foundation
import os

/// One-process launch grants for the cmux CLI -> signed CodeRouter `exec`
/// transition.
///
/// An arm is non-secret. It authorizes only one later audit-token transition
/// for the same PID, listener generation, and ten-second window. Consumption
/// is atomic, so a successful or invalid same-PID attempt cannot be replayed.
final class CodeRouterHandoffArmGrantStore: Sendable {
    static let lifetimeNanoseconds: UInt64 = 10_000_000_000
    static let maximumGrantCount = 64

    enum ArmResult: Sendable, Equatable {
        case armed
        case replay
        case busy
    }

    private struct ReplayKey: Sendable, Hashable {
        let capabilityNonce: Data
        let clientChallenge: Data
        let processID: pid_t
        let processStartTime: SocketPeerProcessStartTime
    }

    private struct Grant: Sendable {
        let token: SocketPeerAuditToken
        let processStartTime: SocketPeerProcessStartTime
        let authorizationGeneration: UInt64
        let sessionBinding: CodeRouterHandoffSessionBinding
        let expiresAtNanoseconds: UInt64
    }

    private struct State: Sendable {
        var grantsByProcessID: [pid_t: Grant] = [:]
        var recentProofs: [ReplayKey: UInt64] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monotonicNowNanoseconds: @Sendable () -> UInt64

    init(
        monotonicNowNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.monotonicNowNanoseconds = monotonicNowNanoseconds
    }

    /// Replaces the pending grant for this PID with one current arm.
    @discardableResult
    func arm(
        token: SocketPeerAuditToken,
        processStartTime: SocketPeerProcessStartTime,
        authorizationGeneration: UInt64,
        sessionBinding: CodeRouterHandoffSessionBinding,
        capabilityNonce: Data,
        clientChallenge: Data
    ) -> Bool {
        armWithResult(
            token: token,
            processStartTime: processStartTime,
            authorizationGeneration: authorizationGeneration,
            sessionBinding: sessionBinding,
            capabilityNonce: capabilityNonce,
            clientChallenge: clientChallenge
        ) == .armed
    }

    func armWithResult(
        token: SocketPeerAuditToken,
        processStartTime: SocketPeerProcessStartTime,
        authorizationGeneration: UInt64,
        sessionBinding: CodeRouterHandoffSessionBinding,
        capabilityNonce: Data,
        clientChallenge: Data
    ) -> ArmResult {
        guard capabilityNonce.count == SocketClientCapabilityProof.byteCount,
              clientChallenge.count == SocketClientCapabilityProof.byteCount else {
            return .busy
        }
        let replayKey = ReplayKey(
            capabilityNonce: capabilityNonce,
            clientChallenge: clientChallenge,
            processID: token.processID,
            processStartTime: processStartTime
        )
        let now = monotonicNowNanoseconds()
        let (candidateExpiry, overflowed) = now.addingReportingOverflow(
            Self.lifetimeNanoseconds
        )
        let expiry = overflowed ? UInt64.max : candidateExpiry
        return state.withLock { state in
            Self.removeExpiredGrants(from: &state, now: now)
            guard state.recentProofs[replayKey] == nil else {
                return .replay
            }
            guard state.recentProofs.count < Self.maximumGrantCount else {
                return .busy
            }
            if state.grantsByProcessID[token.processID] == nil,
               state.grantsByProcessID.count >= Self.maximumGrantCount {
                return .busy
            }
            state.grantsByProcessID[token.processID] = Grant(
                token: token,
                processStartTime: processStartTime,
                authorizationGeneration: authorizationGeneration,
                sessionBinding: sessionBinding,
                expiresAtNanoseconds: expiry
            )
            state.recentProofs[replayKey] = expiry
            return .armed
        }
    }

    /// Atomically consumes a valid arm for a post-`exec` peer token.
    ///
    /// A same-PID attempt always retires its grant. This makes unchanged-token
    /// attempts and malformed launch sequences non-replayable.
    func consume(
        token: SocketPeerAuditToken,
        processStartTime: SocketPeerProcessStartTime,
        authorizationGeneration: UInt64,
        currentSessionBinding: CodeRouterHandoffSessionBinding
    ) -> CodeRouterHandoffSessionBinding? {
        let now = monotonicNowNanoseconds()
        return state.withLock { state in
            Self.removeExpiredGrants(from: &state, now: now)
            guard let grant = state.grantsByProcessID.removeValue(
                forKey: token.processID
            ) else {
                return nil
            }
            guard Self.isValid(
                grant,
                for: token,
                processStartTime: processStartTime,
                authorizationGeneration: authorizationGeneration,
                currentSessionBinding: currentSessionBinding,
                now: now
            ) else {
                return nil
            }
            return grant.sessionBinding
        }
    }

    /// Checks that a grant can begin the post-`exec` challenge without
    /// consuming it. Only the matching completion frame consumes the grant.
    func sessionBindingForBegin(
        token: SocketPeerAuditToken,
        processStartTime: SocketPeerProcessStartTime,
        authorizationGeneration: UInt64,
        currentSessionBinding: CodeRouterHandoffSessionBinding
    ) -> CodeRouterHandoffSessionBinding? {
        let now = monotonicNowNanoseconds()
        return state.withLock { state in
            Self.removeExpiredGrants(from: &state, now: now)
            guard let grant = state.grantsByProcessID[token.processID],
                  Self.isValid(
                    grant,
                    for: token,
                    processStartTime: processStartTime,
                    authorizationGeneration: authorizationGeneration,
                    currentSessionBinding: currentSessionBinding,
                    now: now
                  ) else {
                return nil
            }
            return grant.sessionBinding
        }
    }

    var pendingGrantCount: Int {
        let now = monotonicNowNanoseconds()
        return state.withLock { state in
            Self.removeExpiredGrants(from: &state, now: now)
            return state.grantsByProcessID.count
        }
    }

    private static func removeExpiredGrants(
        from state: inout State,
        now: UInt64
    ) {
        state.grantsByProcessID = state.grantsByProcessID.filter {
            now < $0.value.expiresAtNanoseconds
        }
        state.recentProofs = state.recentProofs.filter {
            now < $0.value
        }
    }

    private static func isValid(
        _ grant: Grant,
        for token: SocketPeerAuditToken,
        processStartTime: SocketPeerProcessStartTime,
        authorizationGeneration: UInt64,
        currentSessionBinding: CodeRouterHandoffSessionBinding,
        now: UInt64
    ) -> Bool {
        grant.authorizationGeneration == authorizationGeneration
            && grant.processStartTime == processStartTime
            && grant.sessionBinding == currentSessionBinding
            && now < grant.expiresAtNanoseconds
            && token != grant.token
            && token.processVersion != grant.token.processVersion
    }
}
