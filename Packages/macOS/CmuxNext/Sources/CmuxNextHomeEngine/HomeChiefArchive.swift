import CmuxNextHomeModel
public import Foundation
public import Observation

/// Archive Chief for one of the account's cloud Chiefs (Home's row menu, the palette, the CLI).
/// The row leaves the list on this Mac at once and stays gone across launches (`hidden`); the
/// cloud's `chief.archive` follows when it can run. Offline or signed out, it runs at the next
/// `chief.list` that answers (``sync(_:)``). The default Chief (the Hosted Chief always is) the
/// cloud never archives (`chief_is_default`): it stays hidden on this Mac only. A refusal for any
/// other reason brings the row back and says why.
@Observable @MainActor
public final class HomeChiefArchive {
    /// What Archive Chief did.
    public enum Outcome: Equatable, Sendable {
        /// The cloud archived it.
        case archived
        /// Hidden on this Mac; the cloud archive waits (offline, signed out, the default Chief).
        case hiddenHere
        /// Not archived, and shown again: the reason.
        case refused(String)
    }

    /// The cloud's answer to one `chief.archive`.
    public enum Reply: Equatable, Sendable {
        case archived
        /// `revision.conflict`: another device changed the Chief.
        case conflict
        /// `chief_is_default`.
        case isDefault
        /// `selector.not_found`: already gone.
        case notFound
        /// Any other refusal, with its message.
        case refused(String)
        /// Signed out, offline, or no reply.
        case unreachable
    }

    /// The account the archive acts on (HomeDirectory's `chief.list` and calls).
    public struct Account {
        /// The active Chiefs of the last `chief.list`.
        public var chiefs: @MainActor () -> [HomeChiefRecord]
        /// The archived and deleted Chiefs of the last `chief.list`.
        public var gone: @MainActor () -> Set<String>
        /// `chief.list` answered this launch.
        public var listed: @MainActor () -> Bool
        /// `chief.archive` of `record` at its revision.
        public var archive: @MainActor (_ record: HomeChiefRecord) async -> Reply
        /// `chief.list` again; false when it did not answer.
        public var reread: @MainActor () async -> Bool
        /// The cloud archived `id`: the account drops it from its active list.
        public var archived: @MainActor (_ id: String) -> Void

        public init(chiefs: @escaping @MainActor () -> [HomeChiefRecord], gone: @escaping @MainActor () -> Set<String>,
                    listed: @escaping @MainActor () -> Bool, archive: @escaping @MainActor (HomeChiefRecord) async -> Reply,
                    reread: @escaping @MainActor () async -> Bool, archived: @escaping @MainActor (String) -> Void) {
            self.chiefs = chiefs
            self.gone = gone
            self.listed = listed
            self.archive = archive
            self.reread = reread
            self.archived = archived
        }
    }

    /// Where `hidden` lives between launches.
    public struct Store {
        let defaults: UserDefaults
        let key: String

        public init(defaults: UserDefaults, key: String = "home.chief.archivedHere") {
            self.defaults = defaults
            self.key = key
        }

        public static var standard: Store { Store(defaults: .standard) }

        func load() -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }

        func save(_ ids: Set<String>) {
            if ids.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(ids.sorted(), forKey: key) }
        }
    }

    /// Chiefs archived on this Mac whose cloud archive no list read has shown yet.
    public private(set) var hidden: Set<String>
    @ObservationIgnored private let store: Store

    public init(store: Store = .standard) {
        self.store = store
        hidden = store.load()
    }

    public func archive(_ id: String, in account: Account) async -> Outcome {
        set(id, hidden: true)
        let step = await cloudArchive(id, in: account)
        let reply: ArchiveOutcomeReply? = try? HomeRules.call("cloud.archive_outcome", ArchiveOutcomeRequest(step: step))
        switch reply?.outcome {
        case .archived?: return .archived
        case .refused(let reason)?:
            set(id, hidden: false)
            return .refused(reason ?? HomeStrings.archiveFailed)
        case .hiddenHere?, nil: return .hiddenHere
        }
    }

    /// After a `chief.list` read: each Chief archived here whose cloud archive is still due gets
    /// it now; one the cloud lists as archived or deleted, or does not list at all (not one of
    /// this account's), needs nothing more from this Mac. A refusal here keeps the Chief hidden
    /// (nobody waits to read it; the next read tries again). The Rust rules decide each
    /// (`cloud.archive_sync`, cmux-home-rules `cloud/archive.rs`).
    public func sync(_ account: Account) async {
        for id in hidden.sorted() {
            // Each pass after an await: the list may be gone (no account to judge by), or a refused
            // archive may have shown the Chief again meanwhile.
            let request = ArchiveSyncRequest(hidden: hidden.contains(id) ? [id] : [], account: ArchiveAccount(account))
            guard let reply: ArchiveSyncReply = try? HomeRules.call("cloud.archive_sync", request) else { continue }
            switch reply.sync[id] {
            case "unhide": set(id, hidden: false)
            case "archive": _ = await cloudArchive(id, in: account)
            default: break
            }
        }
    }

    private func set(_ id: String, hidden on: Bool) {
        if on { hidden.insert(id) } else { hidden.remove(id) }
        store.save(hidden)
    }

    /// `chief.archive` at the record's revision (history stays read-only); one revision conflict
    /// reads the list again and retries. It stays in `hidden` after the cloud archived it, until a
    /// list read shows it archived, so a read already under way then cannot bring the row back.
    /// The steps are the Rust rules' (`cloud.archive_plan`, `cloud.archive_after`).
    private func cloudArchive(_ id: String, in account: Account) async -> ArchiveStep {
        for attempt in 0..<2 {
            let plan = ArchivePlanRequest(id: id, account: ArchiveAccount(account))
            guard let step: ArchiveStep = try? HomeRules.call("cloud.archive_plan", plan) else { return .waits }
            guard case .call(let record) = step else { return step }
            let reply = await account.archive(record.record)
            let after = ArchiveAfterRequest(reply: ArchiveReply(reply), attempt: UInt32(attempt))
            guard let next: ArchiveStep = try? HomeRules.call("cloud.archive_after", after) else { return .waits }
            switch next {
            case .done(dropped: true):
                account.archived(id)
                return next
            case .reread:
                guard await account.reread() else { return .waits }
            default:
                return next
            }
        }
        return .waits
    }
}

/// `HomeChiefRecord` on the `cloud.archive_*` wire (cmux-home-rules `cloud/chiefs.rs` `Record`).
private nonisolated struct ArchiveRecord: Codable {
    var id: String
    var name: String
    var isDefault: Bool
    var rev: Int
    var mainConversation: String?
    var placed: Bool

    init(_ record: HomeChiefRecord) {
        id = record.id
        name = record.name
        isDefault = record.isDefault
        rev = record.rev
        mainConversation = record.mainConversation
        placed = record.placed
    }

    var record: HomeChiefRecord {
        HomeChiefRecord(id: id, name: name, isDefault: isDefault, rev: rev, mainConversation: mainConversation, placed: placed)
    }
}

/// `HomeChiefArchive.Account`'s values now.
private nonisolated struct ArchiveAccount: Encodable {
    var chiefs: [ArchiveRecord]
    var gone: [String]
    var listed: Bool

    @MainActor init(_ account: HomeChiefArchive.Account) {
        chiefs = account.chiefs().map(ArchiveRecord.init)
        gone = account.gone().sorted()
        listed = account.listed()
    }
}

/// One step of the cloud archive (`archive::Step`).
private nonisolated enum ArchiveStep: Codable {
    case call(ArchiveRecord)
    case done(dropped: Bool)
    case waits
    case reread
    case refused(reason: String?)

    private enum Key: String, CodingKey { case kind, record, dropped, reason }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "call": self = .call(try c.decode(ArchiveRecord.self, forKey: .record))
        case "done": self = .done(dropped: try c.decode(Bool.self, forKey: .dropped))
        case "waits": self = .waits
        case "reread": self = .reread
        case "refused": self = .refused(reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "step \(kind)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .call(let record):
            try c.encode("call", forKey: .kind)
            try c.encode(record, forKey: .record)
        case .done(let dropped):
            try c.encode("done", forKey: .kind)
            try c.encode(dropped, forKey: .dropped)
        case .waits: try c.encode("waits", forKey: .kind)
        case .reread: try c.encode("reread", forKey: .kind)
        case .refused(let reason):
            try c.encode("refused", forKey: .kind)
            try c.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

/// `HomeChiefArchive.Reply` on the wire (`archive::Reply`).
private nonisolated struct ArchiveReply: Encodable {
    var kind: String
    var message: String?

    init(_ reply: HomeChiefArchive.Reply) {
        switch reply {
        case .archived: kind = "archived"
        case .conflict: kind = "conflict"
        case .isDefault: kind = "isDefault"
        case .notFound: kind = "notFound"
        case .refused(let text):
            kind = "refused"
            message = text
        case .unreachable: kind = "unreachable"
        }
    }
}

private nonisolated struct ArchivePlanRequest: Encodable {
    var id: String
    var account: ArchiveAccount
}

private nonisolated struct ArchiveAfterRequest: Encodable {
    var reply: ArchiveReply
    var attempt: UInt32
}

private nonisolated struct ArchiveOutcomeRequest: Encodable {
    var step: ArchiveStep
}

private nonisolated struct ArchiveOutcomeReply: Decodable {
    nonisolated enum Outcome: Decodable {
        case archived, hiddenHere, refused(String?)

        private enum Key: String, CodingKey { case kind, reason }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "archived": self = .archived
            case "hiddenHere": self = .hiddenHere
            case "refused": self = .refused(try c.decodeIfPresent(String.self, forKey: .reason))
            case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "outcome \(kind)")
            }
        }
    }

    var outcome: Outcome?
}

private nonisolated struct ArchiveSyncRequest: Encodable {
    var hidden: [String]
    var account: ArchiveAccount
}

private nonisolated struct ArchiveSyncReply: Decodable {
    var sync: [String: String]
}
