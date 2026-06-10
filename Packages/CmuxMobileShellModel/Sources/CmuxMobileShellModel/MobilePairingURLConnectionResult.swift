import Foundation

/// The result of attempting to connect from a pairing URL.
public enum MobilePairingURLConnectionResult: Equatable, Sendable {
    /// The pairing URL produced a live connection.
    case connected
    /// The pairing URL failed to connect.
    case failed
    /// The code was rejected before any pairing attempt was claimed (an
    /// undecodable code scanned while a live session exists): the existing
    /// connection, ticket, and attach authentication were left untouched.
    case rejected
    /// A newer connection attempt superseded this one before it completed.
    case superseded

    /// Whether the result represents a successful connection.
    public var didConnect: Bool {
        self == .connected
    }
}
