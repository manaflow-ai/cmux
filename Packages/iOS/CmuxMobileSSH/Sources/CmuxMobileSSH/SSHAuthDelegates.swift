import NIOCore
import NIOSSH
import os

/// Offers each credential once, in order, for methods the server accepts.
final class SSHCredentialAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let lock = OSAllocatedUnfairLock<[SSHCredential]>(initialState: [])

    init(username: String, credentials: [SSHCredential]) {
        self.username = username
        lock.withLock { $0 = credentials }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let next: SSHCredential? = lock.withLock { remaining in
            while !remaining.isEmpty {
                let candidate = remaining.removeFirst()
                switch candidate {
                case .privateKey where availableMethods.contains(.publicKey):
                    return candidate
                case .password where availableMethods.contains(.password):
                    return candidate
                default:
                    continue
                }
            }
            return nil
        }
        switch next {
        case .privateKey(let key):
            nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
        case .password(let password):
            nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: password))))
        case nil:
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
        }
    }
}

/// Bridges NIO's promise-based host key callback to the async ``SSHHostKeyVerifier``.
///
/// The verifier may wait on the user (a trust prompt), so the handshake
/// deadline is paused for exactly as long as verification is pending.
final class SSHHostKeyAuthDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private struct State {
        var presented: SSHHostKey?
        var rejected = false
        var deadline: SSHHandshakeDeadline?
    }

    private let endpoint: SSHEndpoint
    private let verifier: any SSHHostKeyVerifier
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(endpoint: SSHEndpoint, verifier: any SSHHostKeyVerifier) {
        self.endpoint = endpoint
        self.verifier = verifier
    }

    /// The key the server presented, available once the handshake reached host key validation.
    var presentedKey: SSHHostKey? { state.withLock { $0.presented } }

    /// Whether the verifier declined the presented key. Authoritative over
    /// whatever error the transport surfaces afterwards (NIO may report the
    /// failed validation as a closed channel).
    var rejectedPresentedKey: Bool { state.withLock { $0.rejected } }

    /// The handshake budget to pause while the verifier is pending.
    func pauseDuringVerification(_ deadline: SSHHandshakeDeadline) {
        state.withLock { $0.deadline = deadline }
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = SSHHostKey(hostKey)
        let deadline = state.withLock { state -> SSHHandshakeDeadline? in
            state.presented = key
            return state.deadline
        }
        deadline?.pause()
        let endpoint = endpoint
        let verifier = verifier
        Task {
            let accepted = await verifier.verify(key, for: endpoint)
            if !accepted { state.withLock { $0.rejected = true } }
            deadline?.resume()
            if accepted {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHConnectionError.hostKeyRejected(.unknown(presented: key)))
            }
        }
    }
}
