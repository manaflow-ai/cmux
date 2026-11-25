public import Foundation
import CmuxNextWindowRules

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
    /// When this Mac kept it (``KeptRecord``); nil for a build kept before records.
    public var keptAt: Date?
    /// When it was built, `YYYY-MM-DD`; nil when not known.
    public var date: String?
    /// The commit it was built from (`CMUXCommit` in its Info.plist); nil for a build without it.
    public var commit: String?

    public init(build: String, shortVersion: String, bundle: URL, storeSchemas: [String: Int]?, teamID: String?,
                keptAt: Date? = nil, date: String? = nil, commit: String? = nil) {
        self.build = build
        self.shortVersion = shortVersion
        self.bundle = bundle
        self.storeSchemas = storeSchemas
        self.teamID = teamID
        self.keptAt = keptAt
        self.date = date
        self.commit = commit
    }
}

/// Why a rollback does not run (decision 2026-10-04: refuse rather than
/// lose data the old build cannot read).
nonisolated public enum RollbackRefusal: Error, Equatable, Sendable {
    /// No kept version (or not the one asked for).
    case nothingKept
    /// Builds are kept, but none older than the running one (after a rollback the build left
    /// behind is kept, and it is newer): going back would go forward.
    case nothingOlder(running: String)
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
    /// The kept build is in place, but the helper that reopens cmux did not start.
    case relaunchFailed(KeptVersion)
    /// Another switch or rollback is already running.
    case busy
}

/// Picks the rollback target or refuses. The rules are cmux-updater-core's (`rollback.rs`), asked
/// over the app FFI (`updater_rollback`); this maps the kept builds onto the wire and the answer back.
nonisolated public struct RollbackDecision {
    public init() {}
    /// - Parameters:
    ///   - kept: kept versions, newest first.
    ///   - build: the build asked for, or nil for the previous one (``previous(kept:running:)``).
    ///   - running: the running build; nil only in old callers, which took the newest kept one.
    ///   - stored: the daemon's stored version of every store it has.
    ///   - teamID: this app's signing team.
    public static func decide(kept: [KeptVersion], build: String?, running: String? = nil, stored: [String: Int],
                              teamID: String?) -> Result<KeptVersion, RollbackRefusal> {
        let request = Request(kept: kept.map(Wire.init), build: build, running: running, stored: stored, teamId: teamID,
                              previousOnly: false)
        // A build whose FFI lacks the op refuses: a rollback never runs on a guess.
        guard let reply = WindowRules().call("updater_rollback", request, as: Reply.self) else { return .failure(.nothingKept) }
        func target(_ index: Int?) -> KeptVersion? { index.flatMap { kept.indices.contains($0) ? kept[$0] : nil } }
        if let refusal = reply.refusal {
            let item = target(refusal.kept)
            switch refusal.kind {
            case "nothingOlder": return .failure(.nothingOlder(running: refusal.running ?? running ?? ""))
            case "predatesRollback": if let item { return .failure(.predatesRollback(item)) }
            case "storeTooNew":
                if let item, let store = refusal.store, let storedVersion = refusal.stored, let readable = refusal.readable {
                    return .failure(.storeTooNew(store: store, stored: storedVersion, readable: readable, kept: item))
                }
            case "unknownStore": if let item, let store = refusal.store { return .failure(.unknownStore(store: store, kept: item)) }
            case "signature": if let item { return .failure(.signature(item)) }
            default: break
            }
            return .failure(.nothingKept)
        }
        return target(reply.target).map { .success($0) } ?? .failure(.nothingKept)
    }

    /// The build "go back" means: of the kept builds older than `running` (by number, never one
    /// above it), the one kept most recently, which is the build this Mac updated from; builds with
    /// no keep date after those that have one, the newest number first. Never picked by the order
    /// the folder lists them in.
    public static func previous(kept: [KeptVersion], running: String) -> KeptVersion? {
        let request = Request(kept: kept.map(Wire.init), build: nil, running: running, stored: [:], teamId: nil, previousOnly: true)
        guard let index = WindowRules().call("updater_rollback", request, as: Reply.self)?.target,
              kept.indices.contains(index) else { return nil }
        return kept[index]
    }

    /// cmux-updater-core's `Kept`.
    private struct Wire: Encodable {
        var build: String
        var storeSchemas: [String: Int]?
        var teamId: String?
        var keptAt: Double?

        init(_ kept: KeptVersion) {
            build = kept.build
            storeSchemas = kept.storeSchemas
            teamId = kept.teamID
            keptAt = kept.keptAt?.timeIntervalSince1970
        }
    }

    private struct Request: Encodable {
        var kept: [Wire]
        var build: String?
        var running: String?
        var stored: [String: Int]
        var teamId: String?
        var previousOnly: Bool
    }

    private struct Reply: Decodable {
        struct Refusal: Decodable {
            var kind: String
            var running: String?
            var store: String?
            var stored: Int?
            var readable: Int?
            var kept: Int?
        }

        var target: Int?
        var refusal: Refusal?
    }
}

extension RollbackRefusal {
    /// What the user reads (CLI, palette, dialog).
    public var message: String {
        switch self {
        case .nothingKept:
            UpdaterStrings.rollbackNothingKept
        case .nothingOlder:
            UpdaterStrings.rollbackNothingOlder
        case .predatesRollback(let kept):
            UpdaterStrings.rollbackPredates(kept.shortVersion)
        case .storeTooNew(let store, _, _, let kept):
            UpdaterStrings.rollbackStoreTooNew(kept.shortVersion, store)
        case .unknownStore(let store, let kept):
            UpdaterStrings.rollbackUnknownStore(kept.shortVersion, store)
        case .signature(let kept):
            UpdaterStrings.rollbackSignature(kept.shortVersion)
        case .storesUnknown:
            UpdaterStrings.rollbackStoresUnknown
        case .relaunchFailed(let kept):
            UpdaterStrings.rollbackRelaunchFailed(kept.shortVersion)
        case .busy:
            UpdaterStrings.rollbackBusy
        }
    }
}
