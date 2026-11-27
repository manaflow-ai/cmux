/// In-memory alias-chain resolver over the journal's restore identity maps.
///
/// A replay fold canonicalizes every event's workspace/surface identity; doing
/// that through per-event SQL lookups costs two round-trips per event, so the
/// consumer loads the (tiny) alias tables once and resolves chains here.
/// Semantics match ``AgentJournalStore/resolvedSurfaceId(_:)``: chains are
/// followed up to ``AgentJournalStore/maximumAliasChainLength`` hops, and a
/// recorded cycle fails closed with `nil`.
public struct AgentJournalAliasResolver: Sendable, Equatable {
    /// Old workspace UUID string → new workspace UUID string.
    public private(set) var workspaces: [String: String]
    /// Old surface UUID string → new surface UUID string.
    public private(set) var surfaces: [String: String]

    /// Creates a resolver over the given maps.
    ///
    /// - Parameters:
    ///   - workspaces: Old workspace UUID string → new workspace UUID string.
    ///   - surfaces: Old surface UUID string → new surface UUID string.
    public init(workspaces: [String: String] = [:], surfaces: [String: String] = [:]) {
        self.workspaces = workspaces
        self.surfaces = surfaces
    }

    /// Merges freshly recorded aliases into the resolver.
    ///
    /// - Parameters:
    ///   - workspaces: Newly recorded workspace aliases.
    ///   - surfaces: Newly recorded surface aliases.
    public mutating func merge(workspaces: [String: String], surfaces: [String: String]) {
        self.workspaces.merge(workspaces) { _, new in new }
        self.surfaces.merge(surfaces) { _, new in new }
    }

    /// Resolves a surface identity through the chain.
    ///
    /// - Parameter surfaceId: The (possibly stale) surface UUID string.
    /// - Returns: The current identity, or `nil` on a recorded cycle.
    public func resolvedSurfaceId(_ surfaceId: String) -> String? {
        Self.resolve(surfaceId, in: surfaces)
    }

    /// Resolves a workspace identity through the chain.
    ///
    /// - Parameter workspaceId: The (possibly stale) workspace UUID string.
    /// - Returns: The current identity, or `nil` on a recorded cycle.
    public func resolvedWorkspaceId(_ workspaceId: String) -> String? {
        Self.resolve(workspaceId, in: workspaces)
    }

    private static func resolve(_ identifier: String, in map: [String: String]) -> String? {
        var current = identifier
        var hops = 0
        while hops < AgentJournalStore.maximumAliasChainLength {
            guard let next = map[current], next != current else { return current }
            current = next
            hops += 1
        }
        return nil
    }
}
