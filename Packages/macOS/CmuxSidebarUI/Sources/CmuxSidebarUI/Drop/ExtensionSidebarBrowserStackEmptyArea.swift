public import SwiftUI
public import CmuxAppKitSupportUI
public import CmuxFoundation
public import CmuxSidebarProviderKit
internal import CmuxSidebar

/// The trailing empty strip below an extension sidebar's browser-stack column.
///
/// Double-clicking the strip opens a new tab; dropping a dragged provider row on
/// it appends the row to the end of the ordered list through
/// ``ExtensionSidebarBrowserStackEndDropDelegate``. It renders a top drop
/// indicator when the drag would land at the end of the stack. The view holds no
/// store reference (snapshot-boundary rule): it takes the immutable ordered rows,
/// the drag bindings, the injected ``accent`` color (the app supplies its
/// `cmuxAccentColor()`), and action closures.
@MainActor
public struct ExtensionSidebarBrowserStackEmptyArea: View {
    private let rowSpacing: CGFloat
    private let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    private let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding private var draggedTabId: UUID?
    @Binding private var dropIndicator: SidebarDropIndicator?
    private let accent: Color
    private let onNewTab: () -> Void
    private let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    /// Creates the browser-stack empty-area drop strip.
    /// - Parameters:
    ///   - rowSpacing: The vertical spacing between rows, used to offset the
    ///     top drop indicator.
    ///   - orderedRows: The ordered provider rows in the browser stack.
    ///   - dragAutoScrollController: Drives edge auto-scroll during the drag.
    ///   - draggedTabId: Binding to the workspace id currently being dragged.
    ///   - dropIndicator: Binding to the rendered drop-indicator position.
    ///   - accent: The accent color used to fill the drop indicator.
    ///   - onNewTab: Invoked on a double-click of the empty strip.
    ///   - onMove: Commits the planned end-of-stack move, returning success.
    public init(
        rowSpacing: CGFloat,
        orderedRows: [ExtensionSidebarBrowserStackDropRow],
        dragAutoScrollController: SidebarDragAutoScrollController,
        draggedTabId: Binding<UUID?>,
        dropIndicator: Binding<SidebarDropIndicator?>,
        accent: Color,
        onNewTab: @escaping () -> Void,
        onMove: @escaping (CmuxSidebarProviderWorkspaceMove) -> Bool
    ) {
        self.rowSpacing = rowSpacing
        self.orderedRows = orderedRows
        self.dragAutoScrollController = dragAutoScrollController
        self._draggedTabId = draggedTabId
        self._dropIndicator = dropIndicator
        self.accent = accent
        self.onNewTab = onNewTab
        self.onMove = onMove
    }

    public var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2, perform: onNewTab)
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackEndDropDelegate(
                orderedRows: orderedRows,
                draggedTabId: $draggedTabId,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator,
                onMove: onMove
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(accent)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastWorkspaceId = orderedRows.last?.workspaceId else { return false }
        return indicator.tabId == lastWorkspaceId
    }
}
