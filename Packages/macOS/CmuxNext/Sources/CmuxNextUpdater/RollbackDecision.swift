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
    /// The running daemon cannot report its stored formats.
    case storesUnknown
}

/// Picks the rollback target or refuses (pure).
nonisolated public struct RollbackDecision {
    public init() {}
    /// - Parameters:
    ///   - kept: kept versions, newest first.
    ///   - build: the build asked for, or nil for the newest kept one.
    ///   - stored: the daemon's stored version of every store it has.
    ///   - teamID: this app's signing team.
    public static func decide(kept: [KeptVersion], build: String?, stored: [String: Int], teamID: String?) -> Result<KeptVersion, RollbackRefusal> {
        guard let target = build.map({ wanted in kept.first { $0.build == wanted } }) ?? kept.first else {
            return .failure(.nothingKept)
        }
        guard let teamID, target.teamID == teamID else { return .failure(.signature(target)) }
        guard let readable = target.storeSchemas else { return .failure(.predatesRollback(target)) }
        // Sorted, so the message names the same store every time.
        for (store, version) in stored.sorted(by: { $0.key < $1.key }) {
            guard let reads = readable[store] else { return .failure(.unknownStore(store: store, kept: target)) }
            if version > reads { return .failure(.storeTooNew(store: store, stored: version, readable: reads, kept: target)) }
        }
        return .success(target)
    }
}

extension RollbackRefusal {
    /// What the user reads (CLI, palette, dialog).
    public var message: String {
        switch self {
        case .nothingKept:
            UpdaterStrings.rollbackNothingKept
        case .predatesRollback(let kept):
            UpdaterStrings.rollbackPredates(kept.shortVersion)
        case .storeTooNew(let store, let stored, let readable, let kept):
            UpdaterStrings.rollbackStoreTooNew(kept.shortVersion, store, stored, readable)
        case .unknownStore(let store, let kept):
            UpdaterStrings.rollbackUnknownStore(kept.shortVersion, store)
        case .signature(let kept):
            UpdaterStrings.rollbackSignature(kept.shortVersion)
        case .storesUnknown:
            UpdaterStrings.rollbackStoresUnknown
        }
    }
}
