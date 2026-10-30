import Foundation

/// Native correlation for an asynchronous pending-question read. This primitive only binds
/// one relay token to one recovery epoch; it creates no question, person, nonce, or gesture proof.
public nonisolated struct AcpmuxQuestionReadEpochs: Sendable, Equatable {
    public static let limit = 256

    private var epoch: UInt64 = 0
    private var issued: [Int: UInt64] = [:]

    public init() {}

    /// Register before sending. The caller supplies connection-unique monotonic relay tokens
    /// (AcpmuxRequestIds); this bounded map permits an explicitly reissued retired integer.
    @discardableResult
    public mutating func issue(_ token: Int) -> Bool {
        guard !issued.keys.contains(token), issued.count < Self.limit else { return false }
        issued[token] = epoch
        return true
    }

    /// A request that failed before reaching the daemon does not consume a recovery epoch.
    public mutating func cancel(_ token: Int) {
        issued[token] = nil
    }

    /// Retire every outstanding request after lag, detach, watch-off, or reconnect.
    public mutating func invalidate() {
        epoch &+= 1
        issued.removeAll(keepingCapacity: true)
    }

    /// Redeem exactly one token issued in the current epoch.
    @discardableResult
    public mutating func redeem(_ token: Int) -> Bool {
        guard issued.removeValue(forKey: token) == epoch else { return false }
        return true
    }
}
