import Foundation

/// The sidebar document on the home session (`sidebar-doc-v1`,
/// .cmux-scratch/sidebar-rewrite/CONTRACT.md "Wire"): `sidebar.get`, the
/// move family (`sidebar.move`, `sidebar.pin`, `sidebar.unpin`),
/// `sidebar.apply` (undo and redo with a returned inverse) and
/// `sidebar.adopt`. Values stay JSON here: the client mirror
/// (CmuxNextSidebar `SidebarMirror`) reads them with the same Rust reducer
/// the daemon runs. Deltas arrive on `session.events`
/// (`SessionStateChange.sidebarBatch`).
public struct SidebarDocClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// The whole document: `{revision, sections, items}`.
    public func get() async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "sidebar.get", params: [:], idempotencyKey: nil)
        }, as: JSONValue.self)
    }

    /// Moves `items` to `to` (`{section, parent?, before?|after?|index?}`) as
    /// one change. Returns `{revision, inverse:[op]}`.
    public func move(items: [String], to: JSONValue, idempotencyKey: String) async throws -> SidebarDocMutation {
        try await mutate("sidebar.move", ["items": .array(items.map(JSONValue.string)), "to": to], key: idempotencyKey)
    }

    /// Moves `items` to the end of Pinned (`sidebar.pin`).
    public func pin(items: [String], idempotencyKey: String) async throws -> SidebarDocMutation {
        try await mutate("sidebar.pin", ["items": .array(items.map(JSONValue.string))], key: idempotencyKey)
    }

    /// Moves `items` back to their own machine section, last (`sidebar.unpin`).
    public func unpin(items: [String], idempotencyKey: String) async throws -> SidebarDocMutation {
        try await mutate("sidebar.unpin", ["items": .array(items.map(JSONValue.string))], key: idempotencyKey)
    }

    /// Applies `ops` as one change (undo sends a move's inverse; redo the
    /// inverse this returns).
    public func apply(ops: [JSONValue], idempotencyKey: String) async throws -> SidebarDocMutation {
        try await mutate("sidebar.apply", ["ops": .array(ops)], key: idempotencyKey)
    }

    /// Places live workspaces the document does not hold yet (idempotent).
    public func adopt(refs: [JSONValue], idempotencyKey: String) async throws -> SidebarDocMutation {
        try await mutate("sidebar.adopt", ["refs": .array(refs)], key: idempotencyKey)
    }

    private func mutate(_ operation: String, _ params: [String: JSONValue], key: String) async throws -> SidebarDocMutation {
        let reply = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: key)
        }, as: JSONValue.self)
        return SidebarDocMutation(reply)
    }
}

/// A mutation's reply: the revision after it and the ops that undo it.
/// Read from the reply itself or from a `ResourceMutationResult` `value`.
public struct SidebarDocMutation: Sendable, Hashable {
    public var revision: UInt64?
    public var inverse: [JSONValue]

    public init(revision: UInt64?, inverse: [JSONValue]) {
        self.revision = revision
        self.inverse = inverse
    }

    init(_ reply: JSONValue) {
        guard case .object(var object) = reply else {
            self.init(revision: nil, inverse: [])
            return
        }
        if case .object(let value)? = object["value"] { object = value.merging(object) { inner, _ in inner } }
        self.init(revision: object["revision"].flatMap(Self.revision), inverse: object["inverse"]?.arrayValue ?? [])
    }

    /// The document revision on the wire: a decimal string (or a number from an older build).
    public static func revision(_ value: JSONValue) -> UInt64? {
        switch value {
        case .string(let text): UInt64(text, radix: 10)
        case .number(let number): UInt64(exactly: number)
        default: nil
        }
    }
}
