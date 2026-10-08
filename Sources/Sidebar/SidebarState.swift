import CmuxSidebar
import CmuxWorkspaces
import Combine
import CoreGraphics
import Foundation

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat
    /// Hidden because the window was too narrow (SidePanelWidthFit), not by the
    /// person; session snapshots save it as visible.
    var isAutoCollapsed = false

    /// Whether the sidebar takes layout width or floats over the content.
    ///
    /// Window-scoped rather than global: a user can dock the rail in the window
    /// they are reading a long list in and leave it floating everywhere else.
    /// The last chosen mode is persisted separately as the default for new
    /// windows.
    @Published var presentationMode: SidebarPresentationMode

    /// Whether the sidebar currently consumes layout width from the content.
    ///
    /// The distinction the whole floating mode rests on: a floating sidebar is
    /// still "visible", it simply does not push the terminal aside.
    var occupiesLayout: Bool {
        isVisible && presentationMode == .docked
    }
    private var visibilityWillChangeOwnerId: UUID?
    private var visibilityWillChange: ((Bool) -> Void)?
    /// When installed, user toggles defer to this orchestrator (the toggle
    /// animator's slide), which applies the final value itself once the
    /// slide lands. Returning false hands the change back to the instant
    /// default path. Programmatic `setVisible` calls (narrow-window
    /// auto-collapse, session restore) never animate, so their callers can
    /// read `isVisible` right after.
    var animatedVisibilityOrchestrator: ((Bool) -> Bool)?
    /// Told after every committed ``setVisible(_:)``, so the toggle animator
    /// can drop a running slide and keep its layout flag in step.
    var visibilityDidCommit: ((Bool) -> Void)?
    /// Where a running toggle animation is heading while `isVisible` still
    /// shows the other value. Owned by the toggle animator; nil otherwise.
    var pendingVisibility: Bool?

    /// The visibility the sidebar is heading to, even while a toggle
    /// animation runs. Toggles read this, so a second toggle mid-animation
    /// reverses it instead of being dropped.
    var requestedVisibility: Bool {
        pendingVisibility ?? isVisible
    }

    init(
        isVisible: Bool = true,
        persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth),
        presentationMode: SidebarPresentationMode = .docked
    ) {
        self.isVisible = isVisible
        self.presentationMode = presentationMode
        let sanitized = SessionPersistencePolicy.sanitizedSidebarWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
    }

    func toggle() {
        let nextValue = !requestedVisibility
        if let animatedVisibilityOrchestrator, animatedVisibilityOrchestrator(nextValue) {
            return
        }
        setVisible(nextValue)
    }

    /// Switches between docked and floating.
    func togglePresentationMode() {
        presentationMode = presentationMode.toggled
    }

    func setVisible(_ nextValue: Bool) {
        pendingVisibility = nil
        if nextValue != isVisible {
            visibilityWillChange?(nextValue)
            isVisible = nextValue
        }
        visibilityDidCommit?(nextValue)
    }

    func installVisibilityWillChangeHandler(
        ownerId: UUID,
        _ handler: @escaping (Bool) -> Void
    ) {
        visibilityWillChangeOwnerId = ownerId
        visibilityWillChange = handler
    }

    func removeVisibilityWillChangeHandler(ownerId: UUID) {
        guard visibilityWillChangeOwnerId == ownerId else { return }
        visibilityWillChangeOwnerId = nil
        visibilityWillChange = nil
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

        guard oldWorkspaceIds.count == newWorkspaceIds.count else {
            return false
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
