public import Foundation

/// One app's database in the server's Postgres cluster.
public nonisolated struct ServerDatabase: Sendable, Equatable, Identifiable {
    public var app: String
    public var sizeBytes: Int64
    public var quotaBytes: Int64
    public var id: String { app }

    public init(app: String, sizeBytes: Int64, quotaBytes: Int64) {
        self.app = app
        self.sizeBytes = sizeBytes
        self.quotaBytes = quotaBytes
    }

    /// Used share of the quota, 0...1 (0 without a quota).
    public var usage: Double {
        quotaBytes > 0 ? min(max(Double(sizeBytes) / Double(quotaBytes), 0), 1) : 0
    }
}

public nonisolated enum ServerBrowserState: Sendable, Equatable {
    case off
    case idle
    case running(pages: Int)
    case unavailable
}

public nonisolated struct ServerStoreInfo: Sendable, Equatable {
    public var version: String
    public var channel: String
    public var pinned: Bool

    public init(version: String, channel: String, pinned: Bool) {
        self.version = version
        self.channel = channel
        self.pinned = pinned
    }
}
