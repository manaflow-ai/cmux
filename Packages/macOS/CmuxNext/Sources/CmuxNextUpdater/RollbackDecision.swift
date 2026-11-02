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

/// Picks the rollback target or refuses, with the update rules (cmux-updater-core
/// `updater_rollback_decide`).
nonisolated public struct RollbackDecision {
    public init() {}
    /// - Parameters:
    ///   - kept: kept versions, newest first.
    ///   - build: the build asked for, or nil for the newest kept one.
    ///   - stored: the daemon's stored version of every store it has; nil when it could not say.
    ///   - teamID: this app's signing team.
    public static func decide(kept: [KeptVersion], build: String?, stored: [String: Int]?, teamID: String?) -> Result<KeptVersion, RollbackRefusal> {
        let request = RollbackRequest(kept: kept.map { RollbackRequest.Kept(build: $0.build, storeSchemas: $0.storeSchemas, teamId: $0.teamID) },
                                      build: build, stored: stored, teamId: teamID)
        guard let answer: RollbackAnswer = UpdaterRules().call("updater_rollback_decide", json: request) else {
            return .failure(.storesUnknown)
        }
        let target = { (index: Int?) -> KeptVersion? in index.flatMap { kept.indices.contains($0) ? kept[$0] : nil } }
        if let index = answer.target, let version = target(index) { return .success(version) }
        guard let refusal = answer.refusal else { return .failure(.storesUnknown) }
        let named = target(refusal.kept)
        switch refusal.kind {
        case "nothingKept": return .failure(.nothingKept)
        case "signature": if let named { return .failure(.signature(named)) }
        case "predatesRollback": if let named { return .failure(.predatesRollback(named)) }
        case "unknownStore":
            if let named, let store = refusal.store { return .failure(.unknownStore(store: store, kept: named)) }
        case "storeTooNew":
            if let named, let store = refusal.store, let stored = refusal.stored, let readable = refusal.readable {
                return .failure(.storeTooNew(store: store, stored: stored, readable: readable, kept: named))
            }
        default: break
        }
        return .failure(.storesUnknown)
    }
}

nonisolated private struct RollbackRequest: Encodable {
    nonisolated struct Kept: Encodable {
        var build: String
        var storeSchemas: [String: Int]?
        var teamId: String?
    }

    var kept: [Kept]
    var build: String?
    var stored: [String: Int]?
    var teamId: String?
}

nonisolated private struct RollbackAnswer: Decodable {
    nonisolated struct Refusal: Decodable {
        var kind: String
        var kept: Int?
        var store: String?
        var stored: Int?
        var readable: Int?
    }

    var target: Int?
    var refusal: Refusal?
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
