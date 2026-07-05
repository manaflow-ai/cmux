public import Foundation

/// Builds stable local ids for normalized inbox records.
public struct InboxIdentity: Sendable {
    /// Creates an identity helper.
    public init() {}

    /// Returns a stable local thread id.
    /// - Parameters:
    ///   - source: Source service.
    ///   - accountID: Source account id.
    ///   - externalThreadID: Source thread id.
    public func threadID(source: InboxSource, accountID: String, externalThreadID: String) -> String {
        "thread:\(source.rawValue):\(Self.escape(accountID)):\(Self.escape(externalThreadID))"
    }

    /// Returns a stable local item id.
    /// - Parameters:
    ///   - source: Source service.
    ///   - accountID: Source account id.
    ///   - externalMessageID: Source message id.
    public func itemID(source: InboxSource, accountID: String, externalMessageID: String) -> String {
        "item:\(source.rawValue):\(Self.escape(accountID)):\(Self.escape(externalMessageID))"
    }

    /// Returns a stable local draft id.
    /// - Parameters:
    ///   - threadID: Local thread id.
    ///   - createdAt: Draft creation timestamp.
    public func draftID(threadID: String, createdAt: Date) -> String {
        "draft:\(Self.escape(threadID)):\(Int64(createdAt.timeIntervalSince1970 * 1000)):\(UUID().uuidString)"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: "/", with: "%2F")
    }
}
