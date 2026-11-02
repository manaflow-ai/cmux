public import Foundation

/// A change sent with no answer (a timeout, a closed connection): the daemon may have applied it. The store sends it
/// again under the same idempotency key (the daemon replays a committed change) instead of dropping it.
public nonisolated struct SidebarDocUnsettled: Error, Hashable, Sendable {
    public init() {}
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
