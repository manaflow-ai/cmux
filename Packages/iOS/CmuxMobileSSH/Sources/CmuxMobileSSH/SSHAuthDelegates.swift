import NIOCore
import NIOSSH

/// Offers each credential once, in order, for methods the server accepts.
///
/// NIO asks for the next offer through a promise it waits on, so the actor
/// hop between the callback and the answer costs nothing: NIO does not ask
/// again until the previous offer's promise has completed.
actor SSHCredentialAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var remaining: [SSHCredential]

    init(username: String, credentials: [SSHCredential]) {
        self.username = username
        self.remaining = credentials
    }

    nonisolated func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        Task {
            switch await takeNext(accepting: availableMethods) {
            case .privateKey(let key):
                nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
            case .password(let password):
                nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: password))))
            case nil:
                nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
            }
        }
    }

    /// Removes and returns the first remaining credential whose method the
    /// server accepts, dropping any skipped along the way.
    private func takeNext(accepting availableMethods: NIOSSHAvailableUserAuthenticationMethods) -> SSHCredential? {
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
}

/// Bridges NIO's promise-based host key callback to the async ``SSHHostKeyVerifier``.
///
/// The verifier may wait on the user (a trust prompt), so the handshake
/// deadline is paused for exactly as long as verification is pending.
actor SSHHostKeyAuthDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let endpoint: SSHEndpoint
    private let verifier: any SSHHostKeyVerifier
    /// The handshake budget paused while the verifier is pending.
    private let deadline: SSHHandshakeDeadline

    /// The key the server presented, available once the handshake reached host key validation.
    private(set) var presentedKey: SSHHostKey?

    /// Whether the verifier declined the presented key. Authoritative over
    /// whatever error the transport surfaces afterwards (NIO may report the
    /// failed validation as a closed channel).
    private(set) var rejectedPresentedKey = false

    init(endpoint: SSHEndpoint, verifier: any SSHHostKeyVerifier, deadline: SSHHandshakeDeadline) {
        self.endpoint = endpoint
        self.verifier = verifier
        self.deadline = deadline
    }

    nonisolated func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = SSHHostKey(hostKey)
        // Paused synchronously on the event loop, before the budget can lapse.
        deadline.pause()
        Task {
            let accepted = await verify(key)
            deadline.resume()
            if accepted {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHConnectionError.hostKeyRejected(.unknown(presented: key)))
            }
        }
    }

    /// Records `key` as presented, asks the verifier, and records a refusal.
    private func verify(_ key: SSHHostKey) async -> Bool {
        presentedKey = key
        let accepted = await verifier.verify(key, for: endpoint)
        if !accepted { rejectedPresentedKey = true }
        return accepted
    }
}
