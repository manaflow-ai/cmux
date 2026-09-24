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
final class SSHHostKeyAuthDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let endpoint: SSHEndpoint
    private let verifier: any SSHHostKeyVerifier
    private let presented = OSAllocatedUnfairLock<SSHHostKey?>(initialState: nil)

    init(endpoint: SSHEndpoint, verifier: any SSHHostKeyVerifier) {
        self.endpoint = endpoint
        self.verifier = verifier
    }

    /// The key the server presented, available once the handshake reached host key validation.
    var presentedKey: SSHHostKey? { presented.withLock { $0 } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = SSHHostKey(hostKey)
        presented.withLock { $0 = key }
        let endpoint = endpoint
        let verifier = verifier
        Task {
            if await verifier.verify(key, for: endpoint) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHConnectionError.hostKeyRejected(.unknown(presented: key)))
            }
        }
    }
}
