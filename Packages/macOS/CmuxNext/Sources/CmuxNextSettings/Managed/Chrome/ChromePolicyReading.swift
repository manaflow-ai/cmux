public import Foundation

/// Reads one source of Chrome enterprise policies. Implementations must be
/// cheap enough to call on every settings load and must not block on the network.
public protocol ChromePolicyReading: Sendable {
    func read() -> ChromePolicyDocument
}
