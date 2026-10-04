public import Foundation

/// A previous version kept for rollback (`updates.keepPreviousVersions`).
nonisolated public struct KeptVersion: Equatable, Sendable {
    public var build: String
    public var shortVersion: String
    public var bundle: URL
    /// `CmuxStoreSchemas` from its Info.plist: every daemon store and
    /// protocol it can read, with the newest version it reads. Nil: the
    /// build predates rollback support.
    public var storeSchemas: [String: Int]?
    public var teamID: String?

    public init(build: String, shortVersion: String, bundle: URL, storeSchemas: [String: Int]?, teamID: String?) {
        self.build = build
        self.shortVersion = shortVersion
        self.bundle = bundle
        self.storeSchemas = storeSchemas
        self.teamID = teamID
    }
}

/// Why a rollback does not run (decision 2026-10-04: refuse rather than
/// lose data the old build cannot read).
nonisolated public enum RollbackRefusal: Error, Equatable, Sendable {
    /// No kept version (or not the one asked for).
    case nothingKept
    /// The kept build has no `CmuxStoreSchemas`.
    case predatesRollback(KeptVersion)
    /// A store holds a newer format than the kept build reads.
    case storeTooNew(store: String, stored: Int, readable: Int, kept: KeptVersion)
    /// A store the kept build does not know at all holds data.
    case unknownStore(store: String, kept: KeptVersion)
    /// The kept bundle is not signed by this app's team.
    case signature(KeptVersion)
}

/// Picks the rollback target or refuses (pure).
nonisolated public enum RollbackDecision {
    /// - Parameters:
    ///   - kept: kept versions, newest first.
    ///   - build: the build asked for, or nil for the newest kept one.
    ///   - stored: the daemon's stored version of every store it has.
    ///   - teamID: this app's signing team.
    public static func decide(kept: [KeptVersion], build: String?, stored: [String: Int], teamID: String?) -> Result<KeptVersion, RollbackRefusal> {
        .failure(.nothingKept)
    }
}

extension RollbackRefusal {
    /// Red-test stub.
    public var message: String { "" }
}
