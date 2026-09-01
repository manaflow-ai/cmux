public import Foundation

/// Maps restart-stable object identities to the runtime identities the control
/// socket routes with.
///
/// Workspaces and surfaces carry two identifiers. The runtime id
/// (`Workspace.id` / `Panel.panelId`) is re-minted every launch and is what
/// every resolver matches on. The stable id (`Workspace.stableId` /
/// `Panel.stableSurfaceId`) is persisted in the session snapshot, re-adopted on
/// restore, and is what the UI's copied `cmux://` links carry. Without a
/// mapping, a link that navigates correctly when opened fails with
/// `not_found` when its ids are handed to the CLI.
///
/// Read from both control-socket lanes: the main-actor coordinator and the
/// legacy `nonisolated` param parse, which must not take a main-actor hop just
/// to interpret an identifier. An `NSLock` box therefore replaces the
/// main-actor registry that holds the `kind:N` refs.
///
/// Precedence lives in ``replace(kind:aliases:excludingRuntimeIds:)`` rather
/// than in the lookup: an alias that collides with a live runtime id is dropped
/// when the table is built, so a runtime id can never be reinterpreted as
/// another object's stable id and the lookup stays a single dictionary read.
/// This matches `CmuxNavigationTargetResolver`, which tries the runtime id
/// first and falls back to the stable id.
public final class ControlStableIdentityTable: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimeIdByStableId: [ControlHandleKind: [UUID: UUID]] = [:]

    /// Creates an empty table.
    public init() {}

    /// Replaces the aliases for one handle kind.
    ///
    /// Replacement is wholesale, not a merge: a closed workspace's stable id
    /// must stop resolving rather than route a later command to a dead runtime
    /// id.
    ///
    /// - Parameters:
    ///   - kind: The handle kind these aliases address.
    ///   - aliases: Stable id to current runtime id, for every live object.
    ///   - excludingRuntimeIds: Every live runtime id of this kind. An alias
    ///     keyed by one of these is dropped, so runtime identity always wins.
    public func replace(
        kind: ControlHandleKind,
        aliases: [UUID: UUID],
        excludingRuntimeIds: Set<UUID>
    ) {
        let filtered = aliases.filter { stableId, runtimeId in
            stableId != runtimeId && !excludingRuntimeIds.contains(stableId)
        }
        lock.lock()
        runtimeIdByStableId[kind] = filtered
        lock.unlock()
    }

    /// Maps a caller-supplied identifier to the runtime identity to route with.
    ///
    /// - Parameters:
    ///   - candidate: The identifier the caller supplied.
    ///   - kind: The handle kind the identifier is being used as.
    /// - Returns: The aliased runtime id, or `candidate` unchanged when it is
    ///   already a runtime id or matches no known stable id.
    public func runtimeUUID(for candidate: UUID, kind: ControlHandleKind) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return runtimeIdByStableId[kind]?[candidate] ?? candidate
    }
}
