public import SwiftUI
public import CmuxSidebarProviderKit
import CmuxFoundation
public import CmuxSidebar
public import CmuxAppKitSupportUI

/// A single grid tile in an extension sidebar's browser-stack column.
///
/// Drained byte-identically from `VerticalTabsSidebar.extensionBrowserStackTile`
/// in the app target. The tile renders a provider-supplied icon, draws the
/// selected state with the brown/red accent treatment, and wires drag-reorder
/// (origin drag, drop delegate, top/bottom drop indicators, reorder context
/// menu, accessibility Move Up/Down). Every host reach (workspace selection,
/// reorder mutation) is inverted to ``ExtensionBrowserStackActions``; the drag
/// state lives in the injected ``SidebarDragState`` so this view holds no
/// app-target store reference (snapshot-boundary rule).
public struct ExtensionBrowserStackTileView: View {
    private let row: CmuxSidebarProviderRow
    private let isSelected: Bool
    private let dropRows: [ExtensionSidebarBrowserStackDropRow]
    private let accent: Color
    private let dragState: SidebarDragState
    private let dragAutoScrollController: SidebarDragAutoScrollController
    private let actions: ExtensionBrowserStackActions

    /// Creates a browser-stack grid tile.
    /// - Parameters:
    ///   - row: The provider row this tile represents.
    ///   - isSelected: Whether this tile's workspace is the selected one.
    ///   - dropRows: The ordered drop rows for the whole stack (drag planning).
    ///   - accent: The accent color for the selected-state stroke and indicator.
    ///   - dragState: The shared sidebar drag state.
    ///   - dragAutoScrollController: Drives edge auto-scroll during a drag.
    ///   - actions: The host action bundle for selection and reorder.
    public init(
        row: CmuxSidebarProviderRow,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow],
        accent: Color,
        dragState: SidebarDragState,
        dragAutoScrollController: SidebarDragAutoScrollController,
        actions: ExtensionBrowserStackActions
    ) {
        self.row = row
        self.isSelected = isSelected
        self.dropRows = dropRows
        self.accent = accent
        self.dragState = dragState
        self.dragAutoScrollController = dragAutoScrollController
        self.actions = actions
    }

    private var draggedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { dragState.draggedTabId },
            set: { newValue in
                if let newValue {
                    dragState.draggedTabId = newValue
                } else {
                    dragState.clearDrag()
                }
            }
        )
    }

    private var dropIndicatorBinding: Binding<SidebarDropIndicator?> {
        Binding(
            get: { dragState.dropIndicator },
            set: { dragState.setDropIndicator($0) }
        )
    }

    public var body: some View {
        let targetRowHeight: CGFloat = 54

        return Button {
            actions.selectWorkspace(row.workspaceId)
        } label: {
            ExtensionBrowserStackIcon(icon: row.leadingIcon, size: 28)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            isSelected
                                ? Color(red: 0.44, green: 0.29, blue: 0.23).opacity(0.9)
                                : Color.primary.opacity(0.10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    isSelected ? Color.red.opacity(0.85) : Color.primary.opacity(0.08),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .safeHelp(row.title)
        .opacity(dragState.draggedTabId == row.workspaceId ? 0.55 : 1)
        .onDrag {
            dragState.beginDragging(tabId: row.workspaceId)
            return SidebarTabDragPayload(tabId: row.workspaceId).provider()
        }
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackDropDelegate(
            targetWorkspaceId: row.workspaceId,
            orderedRows: dropRows,
            draggedTabId: draggedTabIdBinding,
            targetRowHeight: targetRowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: dropIndicatorBinding,
            onMove: { move in
                actions.commitMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            ExtensionBrowserStackDropIndicator(
                isActive: dragState.dropIndicator == SidebarDropIndicator(tabId: row.workspaceId, edge: .top),
                accent: accent
            )
        }
        .overlay(alignment: .bottom) {
            ExtensionBrowserStackDropIndicator(
                isActive: dragState.dropIndicator == SidebarDropIndicator(tabId: row.workspaceId, edge: .bottom),
                accent: accent
            )
        }
        .contextMenu {
            ExtensionBrowserStackReorderMenu(
                onMoveUp: { actions.moveWorkspace(row.workspaceId, -1) },
                onMoveDown: { actions.moveWorkspace(row.workspaceId, 1) }
            )
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.",
            bundle: .main
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up", bundle: .main))) {
            actions.moveWorkspace(row.workspaceId, -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down", bundle: .main))) {
            actions.moveWorkspace(row.workspaceId, 1)
        }
    }
}
