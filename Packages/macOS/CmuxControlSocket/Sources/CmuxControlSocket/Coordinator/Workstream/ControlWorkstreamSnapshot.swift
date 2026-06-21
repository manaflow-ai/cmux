public import Foundation

/// A read-only snapshot of one top-level workstream, exposed by the app target
/// to ``ControlCommandCoordinator`` through ``ControlWorkstreamContext``.
///
/// Mirrors the app's `Workstream` (plus its computed membership) without the
/// package importing the app target. The coordinator turns each snapshot into
/// the `workstream.*` payload, minting `workstream` / `workspace` refs itself.
public struct ControlWorkstreamSnapshot: Sendable, Equatable {
    /// The workstream's stable identifier (survives app restart).
    public let id: UUID
    /// The workstream's display name.
    public let name: String
    /// The workstream's custom color override, if any.
    public let customColor: String?
    /// The workstream's custom icon symbol, if any.
    public let iconSymbol: String?
    /// The workstream's member workspace identifiers, in tab order.
    public let memberWorkspaceIDs: [UUID]

    /// Creates a workstream snapshot.
    public init(
        id: UUID,
        name: String,
        customColor: String?,
        iconSymbol: String?,
        memberWorkspaceIDs: [UUID]
    ) {
        self.id = id
        self.name = name
        self.customColor = customColor
        self.iconSymbol = iconSymbol
        self.memberWorkspaceIDs = memberWorkspaceIDs
    }
}
