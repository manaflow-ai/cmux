public import SwiftUI
public import CmuxSidebarProviderKit
import CmuxFoundation
public import CmuxSidebar
public import CmuxAppKitSupportUI

/// A single list row in an extension sidebar's browser-stack column (the loose
/// list under the tile grid and the rows inside grouped sections).
///
/// Drained byte-identically from `VerticalTabsSidebar.extensionBrowserStackRow`
/// in the app target. The row renders the provider icon, title, and resolved
/// trailing text, draws the selected-state fill plus accent stroke, and wires
/// drag-reorder identically to ``ExtensionBrowserStackTileView``. The `compact`
/// flag tightens spacing for grouped rows. Host reaches are inverted to
/// ``ExtensionBrowserStackActions`` and the trailing text is resolved app-side
/// through `actions.renderText` so localization binds to the main bundle.
public struct ExtensionBrowserStackRowView: View {
    private let row: CmuxSidebarProviderRow
    private let now: Date
    private let compact: Bool
    private let isSelected: Bool
    private let dropRows: [ExtensionSidebarBrowserStackDropRow]
    private let accent: Color
    private let dragState: SidebarDragState
    private let dragAutoScrollController: SidebarDragAutoScrollController
    private let actions: ExtensionBrowserStackActions

    /// Creates a browser-stack list row.
    /// - Parameters:
    ///   - row: The provider row this view represents.
    ///   - now: The current time for relative-date trailing text.
    ///   - compact: Whether to render the tighter grouped-row layout.
    ///   - isSelected: Whether this row's workspace is the selected one.
    ///   - dropRows: The ordered drop rows for the whole stack (drag planning).
    ///   - accent: The accent color for the selected-state stroke.
    ///   - dragState: The shared sidebar drag state.
    ///   - dragAutoScrollController: Drives edge auto-scroll during a drag.
    ///   - actions: The host action bundle for selection, reorder, and text.
    public init(
        row: CmuxSidebarProviderRow,
        now: Date,
        compact: Bool = false,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow],
        accent: Color,
        dragState: SidebarDragState,
        dragAutoScrollController: SidebarDragAutoScrollController,
        actions: ExtensionBrowserStackActions
    ) {
        self.row = row
        self.now = now
        self.compact = compact
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
        let targetRowHeight: CGFloat = compact ? 34 : 38

        return Button {
            actions.selectWorkspace(row.workspaceId)
        } label: {
            HStack(spacing: 9) {
                ExtensionBrowserStackIcon(icon: row.leadingIcon, size: compact ? 22 : 24)
                Text(row.title)
                    .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let trailing = actions.renderText(row.trailingText, now) {
                    Text(trailing)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
