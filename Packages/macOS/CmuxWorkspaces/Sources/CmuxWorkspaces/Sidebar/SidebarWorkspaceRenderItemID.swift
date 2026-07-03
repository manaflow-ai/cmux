public import Foundation

/// Stable, allocation-free identity for a ``SidebarWorkspaceRenderItem``.
///
/// `ForEach` gathers row identifiers on every list diff, so the id must be
/// cheap to create and hash. Keep the discriminator as a byte so SwiftUI's
/// per-scroll list diff avoids enum-payload hash/equality witnesses.
public struct SidebarWorkspaceRenderItemID: Hashable, Sendable {
    private let kind: UInt8
    private let uuid: UUID

    /// Creates an identifier for a rendered workspace group header.
    /// - Parameter uuid: The workspace group's stable identifier.
    /// - Returns: A row identifier in the group-header namespace.
    public static func group(_ uuid: UUID) -> Self {
        Self(kind: 1, uuid: uuid)
    }

    /// Creates an identifier for a rendered workspace row.
    /// - Parameter uuid: The workspace's stable identifier.
    /// - Returns: A row identifier in the workspace-row namespace.
    public static func workspace(_ uuid: UUID) -> Self {
        Self(kind: 2, uuid: uuid)
    }

    /// Compares two row identifiers by namespace and UUID.
    /// - Parameters:
    ///   - lhs: The left-hand row identifier.
    ///   - rhs: The right-hand row identifier.
    /// - Returns: `true` when both identifiers refer to the same row namespace and UUID.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.uuid == rhs.uuid
    }

    /// Hashes the row namespace and UUID into `hasher`.
    /// - Parameter hasher: The hasher used by Swift collections and SwiftUI diffing.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(uuid)
    }
}
