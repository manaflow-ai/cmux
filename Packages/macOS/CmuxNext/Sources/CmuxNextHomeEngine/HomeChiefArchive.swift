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
        switch await cloudArchive(id, in: account) {
        case .done: return .archived
        case .waits: return .hiddenHere
        case .refused(let reason):
            set(id, hidden: false)
            return .refused(reason)
        }
    }

    /// After a `chief.list` read: each Chief archived here whose cloud archive is still due gets
    /// it now; one the cloud lists as archived or deleted, or does not list at all (not one of
    /// this account's), needs nothing more from this Mac. A refusal here keeps the Chief hidden
    /// (nobody waits to read it; the next read tries again).
    public func sync(_ account: Account) async {
        for id in hidden.sorted() {
            // Each pass after an await: the list may be gone (no account to judge by), or a refused
            // archive may have shown the Chief again meanwhile.
            guard account.listed(), hidden.contains(id) else { continue }
            let listed = account.chiefs().first { $0.id == id }
            if account.gone().contains(id) || listed == nil {
                set(id, hidden: false)
            } else if listed?.isDefault == false {
                _ = await cloudArchive(id, in: account)
            }
        }
    }

    private enum CloudArchive {
        case done, waits, refused(String)
    }

    private func set(_ id: String, hidden on: Bool) {
        if on { hidden.insert(id) } else { hidden.remove(id) }
        store.save(hidden)
    }

    /// `chief.archive` at the record's revision (history stays read-only); one revision conflict
    /// reads the list again and retries. It stays in `hidden` after the cloud archived it, until a
    /// list read shows it archived, so a read already under way then cannot bring the row back.
    private func cloudArchive(_ id: String, in account: Account) async -> CloudArchive {
        for attempt in 0..<2 {
            guard let record = account.chiefs().first(where: { $0.id == id }) else {
                if account.gone().contains(id) { return .done }
                return account.listed() ? .refused(HomeStrings.archiveFailed) : .waits
            }
            if record.isDefault { return .waits }
            switch await account.archive(record) {
            case .archived, .notFound:
                account.archived(id)
                return .done
            case .conflict:
                guard attempt == 0, await account.reread() else { return .waits }
            case .isDefault, .unreachable:
                return .waits
            case .refused(let message):
                return .refused(message.isEmpty ? HomeStrings.archiveFailed : message)
            }
        }
        return .waits
    }
}
