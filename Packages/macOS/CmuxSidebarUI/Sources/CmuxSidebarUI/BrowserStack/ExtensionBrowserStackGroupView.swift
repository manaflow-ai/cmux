public import SwiftUI
public import CmuxSidebarProviderKit
import CmuxFoundation
public import CmuxSidebar
public import CmuxAppKitSupportUI

/// A collapsible folder group inside an extension sidebar's browser-stack
/// column, rendering a folder header plus its child rows.
///
/// Drained byte-identically from `VerticalTabsSidebar.extensionBrowserStackGroup`
/// in the app target. The header shows the resolved tree-section title; each
/// child renders as a compact ``ExtensionBrowserStackRowView``. The section
/// title is resolved through ``CmuxExtensionSidebarSelection`` (the same path
/// the app used) so localized provider text stays correct.
public struct ExtensionBrowserStackGroupView: View {
    private let section: CmuxSidebarProviderSection
    private let now: Date
    private let dropRows: [ExtensionSidebarBrowserStackDropRow]
    private let selectedWorkspaceId: UUID?
    private let accent: Color
    private let dragState: SidebarDragState
    private let dragAutoScrollController: SidebarDragAutoScrollController
    private let actions: ExtensionBrowserStackActions

    /// Creates a browser-stack folder group.
    /// - Parameters:
    ///   - section: The provider section to render as a group.
    ///   - now: The current time for relative-date trailing text.
    ///   - dropRows: The ordered drop rows for the whole stack (drag planning).
    ///   - selectedWorkspaceId: The id of the currently selected workspace.
    ///   - accent: The accent color for selected-state strokes.
    ///   - dragState: The shared sidebar drag state.
    ///   - dragAutoScrollController: Drives edge auto-scroll during a drag.
    ///   - actions: The host action bundle for selection, reorder, and text.
    public init(
        section: CmuxSidebarProviderSection,
        now: Date,
        dropRows: [ExtensionSidebarBrowserStackDropRow],
        selectedWorkspaceId: UUID?,
        accent: Color,
        dragState: SidebarDragState,
        dragAutoScrollController: SidebarDragAutoScrollController,
        actions: ExtensionBrowserStackActions
    ) {
        self.section = section
        self.now = now
        self.dropRows = dropRows
        self.selectedWorkspaceId = selectedWorkspaceId
        self.accent = accent
        self.dragState = dragState
        self.dragAutoScrollController = dragAutoScrollController
        self.actions = actions
    }

    private func treeSectionTitle(_ section: CmuxSidebarProviderTreeSection) -> String {
        if let titleText = section.titleText {
            return CmuxExtensionSidebarSelection().localizedText(titleText)
        }
        return section.title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
                Text(treeSectionTitle(section.treeSection))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.86))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.rows) { row in
                    ExtensionBrowserStackRowView(
                        row: row,
                        now: now,
                        compact: true,
                        isSelected: row.workspaceId == selectedWorkspaceId,
                        dropRows: dropRows,
                        accent: accent,
                        dragState: dragState,
                        dragAutoScrollController: dragAutoScrollController,
                        actions: actions
                    )
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
    }
}
