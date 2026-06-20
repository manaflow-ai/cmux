import CmuxSidebar
import CmuxWorkspaces
import Combine
import CoreGraphics
import Foundation

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat

    init(isVisible: Bool = true, persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)) {
        self.isVisible = isVisible
        let sanitized = SessionPersistencePolicy.sanitizedSidebarWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
    }

    func toggle() {
        isVisible.toggle()
    }
}

enum SidebarResizeInteraction {
    /// Which side of a divider the resizer band lives on. Maps one-for-one onto
    /// ``CmuxSidebar/SidebarResizerBandPolicy/Edge``; the band math is owned by the
    /// package and this app-side `Edge` forwards into ``bandPolicy``.
    enum Edge {
        case leading
        case trailing

        fileprivate var policyEdge: SidebarResizerBandPolicy.Edge {
            switch self {
            case .leading:
                return .leading
            case .trailing:
                return .trailing
            }
        }

        func handleX(dividerX: CGFloat) -> CGFloat {
            SidebarResizeInteraction.bandPolicy.handleX(for: policyEdge, dividerX: dividerX)
        }

        func hitRange(dividerX: CGFloat) -> ClosedRange<CGFloat> {
            SidebarResizeInteraction.bandPolicy.hitRange(for: policyEdge, dividerX: dividerX)
        }
    }

    // Keep a generous drag target inside the sidebar itself, but keep overlap
    // into terminal/browser content small so edge text selection still wins.
    static let sidebarSideHitWidth: CGFloat = 6
    // 4 pt matches the 4 pt padding used in GhosttySurfaceScrollView drop zone overlays
    // (dropZoneOverlayFrame). This prevents column-0 text near the leading edge from
    // accidentally triggering the sidebar resize when interacting with leftmost content.
    static let contentSideHitWidth: CGFloat = 4

    static var totalHitWidth: CGFloat {
        bandPolicy.totalHitWidth
    }

    /// The single source of truth for the resizer hit-band geometry, owned by
    /// `CmuxSidebar`. Built once from the fixed app-side hit-width constants; the
    /// app's overlay Views and the portal hit-test paths read their band math from
    /// here so the geometry lives in exactly one place.
    static let bandPolicy = SidebarResizerBandPolicy(
        sidebarSideHitWidth: sidebarSideHitWidth,
        contentSideHitWidth: contentSideHitWidth
    )
}

enum SidebarSelectedWorkspaceScrollPolicy {
    static func shouldScrollSelectedWorkspace<ID: Equatable>(
        selectedWorkspaceId: ID?,
        oldWorkspaceIds: [ID],
        newWorkspaceIds: [ID]
    ) -> Bool {
        guard let selectedWorkspaceId,
              let newIndex = newWorkspaceIds.firstIndex(of: selectedWorkspaceId) else {
            return false
        }

        guard let oldIndex = oldWorkspaceIds.firstIndex(of: selectedWorkspaceId) else {
            return true
        }

        guard oldIndex != newIndex else {
            return false
        }

        return true
    }

    /// A member of a collapsed group has no sidebar row of its own, so its
    /// UUID is not a scrollable `.id` and `scrollTo` would no-op. Target the
    /// group header (which carries the anchor workspace id) so the scroll
    /// still lands where the workspace lives. Decided purely from model data,
    /// never from what the lazy layout happens to have realized.
    static func scrollTargetWorkspaceId(
        selectedWorkspaceId: UUID,
        group: WorkspaceGroup?
    ) -> UUID {
        guard let group, group.isCollapsed else { return selectedWorkspaceId }
        return group.anchorWorkspaceId
    }
}
