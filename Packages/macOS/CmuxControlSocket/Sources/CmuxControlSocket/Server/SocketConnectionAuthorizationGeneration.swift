import Foundation

/// Immutable authorization generation captured when a socket is accepted.
struct SocketConnectionAuthorizationGeneration: Sendable {
    let number: UInt64
    let revocationSignal: SocketAuthorizationRevocationSignal
}
