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

enum SidebarPositionOption: String, CaseIterable, Identifiable {
    case left
    case top
    case right
    case bottom

    var id: String { rawValue }

    var isHorizontal: Bool {
        switch self {
        case .top, .bottom:
            return true
        case .left, .right:
            return false
        }
    }
}

enum SidebarPositionSettings {
    static let key = "sidebarPosition"
    static let defaultPosition = SidebarPositionOption.left
    static let horizontalBarHeight: CGFloat = 48

    static func resolved(rawValue: String?) -> SidebarPositionOption {
        guard let rawValue else { return defaultPosition }
        return SidebarPositionOption(rawValue: rawValue) ?? defaultPosition
    }
}

enum SidebarContentLayoutMode: Equatable {
    case leftOverlay
    case leftStack
    case rightStack
    case topStack
    case bottomStack
}

enum SidebarContentLayoutPolicy {
    static func mode(
        position: SidebarPositionOption,
        usesWithinWindowOverlay: Bool
    ) -> SidebarContentLayoutMode {
        switch position {
        case .left:
            return usesWithinWindowOverlay ? .leftOverlay : .leftStack
        case .right:
            // Right-positioned workspace sidebar stays in stack layout even when
            // within-window material is enabled. The app can already host the
            // tool sidebar on the trailing edge, and a single stacked trailing
            // geometry keeps both sidebar dividers deterministic.
            return .rightStack
        case .top:
            return .topStack
        case .bottom:
            return .bottomStack
        }
    }

    static func rightSidebarAvailableWidth(
        totalWidth: CGFloat,
        workspaceSidebarWidth: CGFloat,
        position: SidebarPositionOption,
        isWorkspaceSidebarVisible: Bool
    ) -> CGFloat {
        let sanitizedTotalWidth = max(0, totalWidth)
        guard isWorkspaceSidebarVisible, position == .right else {
            return sanitizedTotalWidth
        }
        return max(0, sanitizedTotalWidth - max(0, workspaceSidebarWidth))
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
