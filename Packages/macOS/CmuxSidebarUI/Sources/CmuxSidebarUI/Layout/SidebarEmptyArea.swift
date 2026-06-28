public import SwiftUI
public import CmuxAppKitSupportUI
public import CmuxFoundation
internal import CmuxSidebar

/// The tap/drop target filling the empty region below the sidebar's workspace
/// rows (and, in the background variant, behind the whole list).
///
/// A double-tap spawns a new workspace and re-syncs the selection through the
/// injected ``SidebarEmptyAreaActions``; the region accepts both a workspace
/// reorder drop (via the passed-in ``SidebarTabDropDelegate``) and a bonsplit
/// tab-to-new-workspace drop (via the injected app-target overlay closure). All
/// live state arrives as value snapshots, closures, or bindings so the view
/// holds no `@Observable` store reference (snapshot-boundary rule).
@MainActor
public struct SidebarEmptyArea: View {
    private let rowSpacing: CGFloat
    @Binding private var selectedTabIds: Set<UUID>
    @Binding private var lastSidebarSelectionIndex: Int?
    private let dragAutoScrollController: SidebarDragAutoScrollController
    private let actions: SidebarEmptyAreaActions
    // Value snapshot + closure bundles instead of an @Observable store
    // reference (snapshot-boundary rule).
    private let topDropIndicatorVisible: Bool
    private let tabDropDelegate: SidebarTabDropDelegate
    private let bonsplitDropIndicator: Binding<SidebarDropIndicator?>
    // App-target `SidebarBonsplitTabNewWorkspaceDropOverlay` injected as an
    // erased view, since it lives in the app target (ContentView+MoveTabToNewWorkspace).
    private let bonsplitDropOverlay: () -> AnyView
    // App-resolved accent color for the top-edge indicator (`cmuxAccentColor()`),
    // evaluated lazily only when the indicator is visible.
    private let topDropIndicatorColor: () -> Color
    private let expandsVertically: Bool
    private let minimumHeight: CGFloat?

    /// Creates the sidebar empty-area target.
    /// - Parameters:
    ///   - rowSpacing: The workspace-row spacing, used to offset the top indicator.
    ///   - selectedTabIds: Binding to the sidebar multi-selection.
    ///   - lastSidebarSelectionIndex: Binding to the sidebar selection anchor index.
    ///   - dragAutoScrollController: Drives edge auto-scroll while hovering.
    ///   - actions: App-target side effects for the double-tap new-workspace flow.
    ///   - topDropIndicatorVisible: Whether to draw the top-edge reorder indicator.
    ///   - tabDropDelegate: The workspace reorder drop delegate for this region.
    ///   - bonsplitDropIndicator: Binding the bonsplit overlay writes its indicator to.
    ///   - topDropIndicatorColor: App-resolved accent color for the top indicator.
    ///   - bonsplitDropOverlay: App-target bonsplit tab-to-new-workspace drop overlay.
    ///   - expandsVertically: Whether the hit target fills available height.
    ///   - minimumHeight: Minimum height when not expanding vertically.
    public init(
        rowSpacing: CGFloat,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>,
        dragAutoScrollController: SidebarDragAutoScrollController,
        actions: SidebarEmptyAreaActions,
        topDropIndicatorVisible: Bool,
        tabDropDelegate: SidebarTabDropDelegate,
        bonsplitDropIndicator: Binding<SidebarDropIndicator?>,
        topDropIndicatorColor: @escaping () -> Color,
        bonsplitDropOverlay: @escaping () -> AnyView,
        expandsVertically: Bool = true,
        minimumHeight: CGFloat? = nil
    ) {
        self.rowSpacing = rowSpacing
        self._selectedTabIds = selectedTabIds
        self._lastSidebarSelectionIndex = lastSidebarSelectionIndex
        self.dragAutoScrollController = dragAutoScrollController
        self.actions = actions
        self.topDropIndicatorVisible = topDropIndicatorVisible
        self.tabDropDelegate = tabDropDelegate
        self.bonsplitDropIndicator = bonsplitDropIndicator
        self.topDropIndicatorColor = topDropIndicatorColor
        self.bonsplitDropOverlay = bonsplitDropOverlay
        self.expandsVertically = expandsVertically
        self.minimumHeight = minimumHeight
    }

    public var body: some View {
        hitTarget
            .onTapGesture(count: 2) {
                // When the active workspace is a remote-tmux mirror, route through
                // performNewWorkspaceAction so a new workspace becomes a new tmux
                // session instead of a local (orphan) workspace. Gate on the
                // SELECTED tab, not `tabs.contains`: a dedicated remote window can
                // be polluted with a dragged-in local workspace (move targets don't
                // exclude dedicated windows), and `contains` would then misroute a
                // local empty-area double-tap into spawning an unwanted tmux session.
                if actions.selectedTabIsRemoteTmuxMirror() {
                    actions.performNewWorkspaceAction()
                } else {
                    actions.addWorkspaceAtEnd()
                }
                if let selectedId = actions.selectedTabId() {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = actions.tabIndex(selectedId)
                }
                actions.selectTabs()
            }
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegate)
            .overlay {
                bonsplitDropOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                if topDropIndicatorVisible {
                    Rectangle()
                        .fill(topDropIndicatorColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    @ViewBuilder
    private var hitTarget: some View {
        if expandsVertically {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: minimumHeight ?? 0)
                .contentShape(Rectangle())
        }
    }
}
