internal import CmuxSettings
internal import CryptoKit
internal import Foundation
internal import os

/// Synchronous authorization-generation state shared by the main-actor
/// listener lifecycle and dedicated blocking client threads.
///
/// Password I/O is performed before taking the lock. Critical sections only
/// compare immutable fingerprints and rotate the generation's pollable
/// revocation signal, so client threads never hold a lock across file I/O.
final class SocketConnectionAuthorizationState: Sendable {
    struct Generation: Sendable {
        let number: UInt64
        let revocationSignal: SocketAuthorizationRevocationSignal
    }

    private struct State: Sendable {
        var accessMode: SocketControlMode = .cmuxOnly
        var isRunning = false
        var passwordFingerprint: Data?
        var generation = Generation(
            number: 0,
            revocationSignal: SocketAuthorizationRevocationSignal()
        )
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var accessMode: SocketControlMode {
        state.withLock { $0.accessMode }
    }

    var currentGeneration: Generation {
        state.withLock { $0.generation }
    }

    func configure(accessMode: SocketControlMode, effectivePassword: String?) {
        let fingerprint = accessMode.requiresPasswordAuth
            ? Self.fingerprint(effectivePassword)
            : nil
        state.withLock { state in
            let policyChanged = state.accessMode != accessMode
            let passwordChanged = accessMode.requiresPasswordAuth
                && state.passwordFingerprint != fingerprint
            state.accessMode = accessMode
            state.passwordFingerprint = fingerprint
            if policyChanged || passwordChanged {
                Self.rotate(&state)
            }
        }
    }

    func setRunning(_ isRunning: Bool) {
        state.withLock { state in
            guard state.isRunning != isRunning else { return }
            state.isRunning = isRunning
            if !isRunning {
                Self.rotate(&state)
            }
        }
    }

    /// Refreshes the effective password and rotates only when password mode's
    /// authoritative credential actually changed.
    @discardableResult
    func refreshEffectivePassword(_ effectivePassword: String?) -> Generation? {
        let fingerprint = Self.fingerprint(effectivePassword)
        return state.withLock { state in
            guard state.accessMode.requiresPasswordAuth,
                  state.passwordFingerprint != fingerprint else {
                return nil
            }
            state.passwordFingerprint = fingerprint
            Self.rotate(&state)
            return state.generation
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock {
            $0.isRunning && $0.generation.number == generation
        }
    }

    private static func rotate(_ state: inout State) {
        let previousSignal = state.generation.revocationSignal
        state.generation = Generation(
            number: state.generation.number &+ 1,
            revocationSignal: SocketAuthorizationRevocationSignal()
        )
        previousSignal.revoke()
    }

    private static func fingerprint(_ password: String?) -> Data? {
        password.map { Data(SHA256.hash(data: Data($0.utf8))) }
    }
}
