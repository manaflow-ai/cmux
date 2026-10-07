import Foundation

/// The sidebar section layout as protocol-v2 state operations
/// (`sidebar-layout-v1`, plans/cmux-next/sidebar-sections.md 5):
/// `sidebar_layout.get` and `sidebar_layout.update {op}` with the client's
/// idempotency key. Values stay JSON here; the App decodes them with the
/// sidebar's document types (this module does not import the sidebar).
public struct SidebarLayoutStateClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// The stored layout (`SidebarLayoutSnapshot`: revision as a decimal string).
    public func get() async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "sidebar_layout.get", params: [:], idempotencyKey: nil)
        }, as: JSONValue.self)
    }

    /// Applies one op under `idempotencyKey`; returns the layout after it
    /// and whether the daemon replayed an earlier result for the key.
    public func update(op: JSONValue, idempotencyKey: String) async throws -> (layout: JSONValue, replayed: Bool) {
        let result = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "sidebar_layout.update", params: ["op": op], idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self)
        return (result.value, result.replayed ?? false)
    }
}
