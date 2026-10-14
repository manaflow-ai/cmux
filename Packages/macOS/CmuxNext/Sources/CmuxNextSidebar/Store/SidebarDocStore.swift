import Foundation
public import Observation

/// The home session's sidebar document as this app shows it
/// (`sidebar-doc-v1`). The daemon owns the document; this store keeps the
/// client mirror (`SidebarMirror`: confirmed document plus pending intents,
/// ordered and judged by the Rust reducer) and the records the rows draw.
/// Every move is one intent: applied to the mirror at once, sent as one
/// `sidebar.move` (or pin, unpin, apply) with an idempotency key, settled
/// by the daemon's echoed batch, and undone with the inverse the daemon
/// returns (one undo entry per move). A batch whose revision skips one
/// refetches the document.
@Observable @MainActor
public final class SidebarDocStore {
    /// The records of the confirmed document.
    public private(set) var records = SidebarDocRecords()
    /// Changes whenever what the sidebar draws may have changed (a load, a
    /// batch, an intent): the bridge rebuilds its rows on it.
    public private(set) var version: UInt64 = 0
    /// The document is loaded and the daemon serves it: the sidebar draws
    /// it. False keeps the older path.
    public private(set) var isActive = false
    /// What the sidebar draws from the document (`show(live:)`); nil while inactive.
    public internal(set) var shown: SidebarDocProjection?

    @ObservationIgnored private let mirror: SidebarMirror?
    @ObservationIgnored private let remote: (any SidebarDocRemote)?
    /// A refusal or failure to show (the refusal HUD).
    @ObservationIgnored public var onRefused: (String) -> Void = { _ in }
    /// A user's move that can be undone: the title and the undo. The App
    /// puts it on its undo surface (the toast and Cmd-Z).
    @ObservationIgnored public var onUndoable: (String, @escaping @MainActor () -> Void) -> Void = { _, _ in }
    @ObservationIgnored private var loading = false
    /// The last projection (`projection(live:)`), by version and live set.
    @ObservationIgnored var projectionCache: (version: UInt64, live: [SidebarDocWorkspaceRef], projection: SidebarDocProjection)?
    /// Refs already sent to `sidebar.adopt` this session.
    @ObservationIgnored private var adopting: Set<SidebarDocWorkspaceRef> = []

    /// The app's one document store (one home session per app); the
    /// App's composition root sets it.
    public static var current: SidebarDocStore?

    public init(remote: (any SidebarDocRemote)?, mirror: SidebarMirror? = SidebarMirror.make()) {
        self.remote = remote
        self.mirror = mirror
    }

    /// Whether this build and the daemon can use the document at all.
    public var isSupported: Bool { mirror != nil && (remote?.isAvailable ?? false) }

    // MARK: Following the daemon

    /// Fetches the whole document (the first load, a reconnect, a stream
    /// snapshot, a revision gap).
    public func refresh() {
        guard isSupported, !loading, let remote, let mirror else {
            if isActive, !isSupported { isActive = false; shown = nil; bump() }
            return
        }
        loading = true
        // task-owner: one sidebar.get; settles the load
        Task { [weak self] in
            defer { self?.loading = false }
            guard let data = try? await remote.get(), let records = try? SidebarDocRecords(document: data), let self else { return }
            guard mirror.load(data) else { return }
            self.records = records
            self.isActive = true
            self.bump()
        }
    }

    /// One `session.events` batch of document changes (JSON, with its
    /// revision and idempotency key).
    public func receive(batch data: Data) {
        guard isActive, let mirror else { return }
        // The reducer judges the revision chain: a skipped one refetches.
        switch mirror.apply(batch: data) {
        case .stale: return
        case .refetch: return refresh()
        case .applied(let revision):
            records.apply(batch: data)
            if let revision { records.revision = revision }
            bump()
        }
    }

    /// Asks the daemon to place live workspaces the document lacks (each once).
    public func adopt(_ refs: [SidebarDocWorkspaceRef]) {
        let fresh = refs.filter { !adopting.contains($0) }
        guard isActive, !fresh.isEmpty, let remote else { return }
        adopting.formUnion(fresh)
        // task-owner: one sidebar.adopt; its batch places the rows
        Task { _ = try? await remote.adopt(fresh, key: Self.newKey()) }
    }

    // MARK: Reading

    /// The rows to draw, in order (one FFI call; only on a structural rebuild).
    public func rows(_ request: SidebarViewRequest) -> [SidebarDocRow]? {
        isActive ? mirror?.rows(request) : nil
    }

    /// What a drop of `items` may do beside each row (one FFI call per drag).
    public func acceptance(dragging items: [String]) -> [String: SidebarDocAcceptance] {
        isActive ? mirror?.acceptance(dragging: items) ?? [:] : [:]
    }

    public static let pinnedSection = "sec_pinned"

    // MARK: Intents

    /// Moves `items` to `target` as one change and one undo step titled `title`.
    public func move(_ items: [String], to target: SidebarDocTarget, title: String) {
        send(.move(items, to: target, key: Self.newKey()), title: title) { remote, key in
            try await remote.move(items, to: target, key: key)
        }
    }

    /// Pin: the items move to the end of Pinned.
    public func pin(_ items: [String], title: String) {
        send(.pin(items, key: Self.newKey()), title: title) { remote, key in
            try await remote.pin(items, key: key)
        }
    }

    /// Unpin: each item moves to the end of its own machine section.
    public func unpin(_ items: [String], title: String) {
        send(.unpin(items, key: Self.newKey()), title: title) { remote, key in
            try await remote.unpin(items, key: key)
        }
    }

    /// Applies ops the daemon returned as an inverse (undo, then redo).
    private func apply(_ ops: Data, title: String) {
        send(.apply(ops, key: Self.newKey()), title: title) { remote, key in
            try await remote.apply(ops: ops, key: key)
        }
    }

    private func send(_ intent: SidebarMirrorIntent, title: String,
                      _ body: @escaping @MainActor (any SidebarDocRemote, String) async throws -> SidebarDocReply) {
        guard isActive, let mirror, let remote else { return onRefused(SidebarDocStrings.unavailable) }
        do {
            try mirror.apply(intent: intent)
        } catch let refusal as SidebarMirror.Refusal {
            return onRefused(SidebarDocStrings.refused(refusal.code))
        } catch {
            return onRefused(SidebarDocStrings.unavailable)
        }
        bump()
        let key = intent.idempotencyKey
        // task-owner: one sidebar mutation; settles its pending intent
        Task { [weak self] in
            do {
                let reply = try await body(remote, key)
                guard let self else { return }
                if reply.hasInverse {
                    let inverse = reply.inverse
                    self.onUndoable(title) { [weak self] in self?.apply(inverse, title: title) }
                }
            } catch {
                guard let self else { return }
                // The daemon refused it: no batch will echo the key.
                self.drop(key)
                self.onRefused(SidebarDocStrings.describe(error))
            }
        }
    }

    private func drop(_ key: String) {
        mirror?.reject(key)
        bump()
    }

    private func bump() { version &+= 1 }

    static func newKey() -> String { "sidebar-" + UUID().uuidString.lowercased() }
}

/// The daemon side of the document (the App's home daemon connection).
@MainActor
public protocol SidebarDocRemote: AnyObject {
    /// The home daemon is connected and serves `sidebar-doc-v1`.
    var isAvailable: Bool { get }
    /// `sidebar.get`, as JSON.
    func get() async throws -> Data
    func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply
    func pin(_ items: [String], key: String) async throws -> SidebarDocReply
    func unpin(_ items: [String], key: String) async throws -> SidebarDocReply
    func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply
    /// `sidebar.apply {ops}`; `ops` is a JSON array.
    func apply(ops: Data, key: String) async throws -> SidebarDocReply
}

/// A mutation's reply: the revision after it and its inverse ops (a JSON array).
public nonisolated struct SidebarDocReply: Hashable, Sendable {
    public var revision: UInt64?
    public var inverse: Data

    public init(revision: UInt64?, inverse: Data) {
        self.revision = revision
        self.inverse = inverse
    }

    /// The inverse holds at least one op.
    public var hasInverse: Bool {
        guard let ops = try? JSONSerialization.jsonObject(with: inverse) as? [Any] else { return false }
        return !ops.isEmpty
    }
}
