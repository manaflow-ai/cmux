public import Foundation

public nonisolated enum AppServerState: String, Sendable, Equatable, Codable {
    case starting, running, draining, crashloop, stopped
}

/// What an app server's data survives (server.md 7.3 and gap G1):
/// `zeroLoss` = acknowledged writes are in R2; `bounded` = up to the
/// shipping or WAL archive lag.
public nonisolated enum AppDataDurability: String, Sendable, Equatable, Codable {
    case zeroLoss = "zero-loss"
    case bounded
}

/// One app's server (the manifest `server` block, server.md 7). Exactly one
/// host per team holds its lease; `holdsLease` says whether it is this one.
public nonisolated struct ServerAppServer: Sendable, Equatable, Identifiable {
    public var appID: String
    public var name: String
    public var state: AppServerState
    public var leaseEpoch: UInt64
    public var holdsLease: Bool
    public var durability: AppDataDurability
    public var lastRestart: Date?
    public var id: String { appID }

    public init(appID: String, name: String, state: AppServerState, leaseEpoch: UInt64, holdsLease: Bool,
                durability: AppDataDurability, lastRestart: Date?) {
        self.appID = appID
        self.name = name
        self.state = state
        self.leaseEpoch = leaseEpoch
        self.holdsLease = holdsLease
        self.durability = durability
        self.lastRestart = lastRestart
    }
}
