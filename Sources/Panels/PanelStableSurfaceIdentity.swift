import Foundation

/// Boxed restart-stable surface identity for durable deep links.
///
/// ``Panel/id`` is a runtime instance handle re-minted every time a panel is
/// recreated, including session restore. This identity is persisted in the
/// session snapshot and re-adopted only by identity-preserving replacement paths
/// so copied `cmux://workspace/<workspace>/surface/<surface>` links keep
/// resolving across app restarts.
@MainActor
public final class PanelStableSurfaceIdentity {
    fileprivate(set) var id = UUID()

    public init() {}
}

extension Panel {
    /// Restart-stable identifier for the surface (tab) this panel hosts.
    var stableSurfaceId: UUID { stableSurfaceIdentity.id }

    /// Re-adopts a persisted surface id during restore or in-place replacement.
    func adoptStableSurfaceId(_ id: UUID) {
        stableSurfaceIdentity.id = id
    }
}
