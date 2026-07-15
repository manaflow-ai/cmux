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
    // Dedicated blocking socket threads require synchronous fail-closed reads;
    // every critical section is bounded and performs no file or Keychain I/O.
    private let state = OSAllocatedUnfairLock(
        initialState: SocketConnectionAuthorizationSnapshot()
    )

    var accessMode: SocketControlMode {
        state.withLock { $0.accessMode }
    }

    var currentGeneration: SocketConnectionAuthorizationGeneration {
        state.withLock { $0.generation }
    }

    func configure(accessMode: SocketControlMode, effectivePassword: String?) {
        let fingerprint = accessMode.requiresPasswordAuth
            ? fingerprint(effectivePassword)
            : nil
        state.withLock { state in
            let policyChanged = state.accessMode != accessMode
            let passwordChanged = accessMode.requiresPasswordAuth
                && state.passwordFingerprint != fingerprint
            state.accessMode = accessMode
            state.passwordFingerprint = fingerprint
            if policyChanged || passwordChanged {
                rotate(&state)
            }
        }
    }

    func setRunning(_ isRunning: Bool) {
        state.withLock { state in
            guard state.isRunning != isRunning else { return }
            state.isRunning = isRunning
            if !isRunning {
                rotate(&state)
            }
        }
    }

    /// Refreshes the effective password and rotates only when password mode's
    /// authoritative credential actually changed.
    @discardableResult
    func refreshEffectivePassword(
        _ effectivePassword: String?
    ) -> SocketConnectionAuthorizationGeneration? {
        let fingerprint = fingerprint(effectivePassword)
        return state.withLock { state in
            guard state.accessMode.requiresPasswordAuth,
                  state.passwordFingerprint != fingerprint else {
                return nil
            }
            state.passwordFingerprint = fingerprint
            rotate(&state)
            return state.generation
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock {
            $0.isRunning && $0.generation.number == generation
        }
    }

    func permitsContinuation(
        generation: UInt64,
        authenticatedPasswordFingerprint: Data?
    ) -> Bool {
        state.withLock { state in
            guard state.isRunning, state.generation.number == generation else {
                return false
            }
            guard state.accessMode.requiresPasswordAuth,
                  let authenticatedPasswordFingerprint else {
                // Password-mode clients remain connected long enough to log in.
                return true
            }
            return authenticatedPasswordFingerprint == state.passwordFingerprint
        }
    }

    private func rotate(_ state: inout SocketConnectionAuthorizationSnapshot) {
        let previousSignal = state.generation.revocationSignal
        state.generation = SocketConnectionAuthorizationGeneration(
            number: state.generation.number &+ 1,
            revocationSignal: SocketAuthorizationRevocationSignal()
        )
        previousSignal.revoke()
    }

    private func fingerprint(_ password: String?) -> Data? {
        password.map { Data(SHA256.hash(data: Data($0.utf8))) }
    }
}
