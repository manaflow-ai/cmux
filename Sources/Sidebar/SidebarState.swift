import Combine
import CoreGraphics

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
    enum Edge {
        case leading
        case trailing

        private var hitWidthBeforeDivider: CGFloat {
            switch self {
            case .leading:
                return SidebarResizeInteraction.sidebarSideHitWidth
            case .trailing:
                return SidebarResizeInteraction.contentSideHitWidth
            }
        }

        func handleX(dividerX: CGFloat) -> CGFloat {
            dividerX - hitWidthBeforeDivider
        }

        func hitRange(dividerX: CGFloat) -> ClosedRange<CGFloat> {
            let minX = handleX(dividerX: dividerX)
            return minX...(minX + SidebarResizeInteraction.totalHitWidth)
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
        sidebarSideHitWidth + contentSideHitWidth
    }
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
}
