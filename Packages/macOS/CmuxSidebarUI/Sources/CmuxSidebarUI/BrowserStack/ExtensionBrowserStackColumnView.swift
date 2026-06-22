public import SwiftUI
public import CmuxSidebarProviderKit
import CmuxFoundation
public import CmuxSidebar
public import CmuxAppKitSupportUI

/// The full browser-stack column rendered for an extension sidebar provider: a
/// three-up tile grid, a loose row list, folder groups, a New Tab button, and a
/// trailing empty drop strip.
///
/// Drained byte-identically from
/// `VerticalTabsSidebar.extensionBrowserStackSidebar` in the app target. The
/// section bucketing (`tiles`/`loose`/grouped), the tile-grid striding, and the
/// fallback prefix/drop slicing match the original exactly. The ordered drop
/// rows are derived here from the render model (a pure projection); every host
/// reach is inverted to ``ExtensionBrowserStackActions``, and layout metrics
/// the app owns (`tabRowSpacing`, `bottomPadding`) are injected so this view
/// holds no app-target metrics dependency.
public struct ExtensionBrowserStackColumnView: View {
    private let model: CmuxSidebarProviderRenderModel
    private let now: Date
    private let selectedWorkspaceId: UUID?
    private let tabRowSpacing: CGFloat
    private let bottomPadding: CGFloat
    private let accent: Color
    private let dragState: SidebarDragState
    private let dragAutoScrollController: SidebarDragAutoScrollController
    private let actions: ExtensionBrowserStackActions

    /// Creates the browser-stack column.
    /// - Parameters:
    ///   - model: The provider render model whose sections drive the layout.
    ///   - now: The current time for relative-date trailing text.
    ///   - selectedWorkspaceId: The id of the currently selected workspace, or
    ///     `nil` (the first tile renders selected when nothing is selected).
    ///   - tabRowSpacing: The vertical spacing fed to the empty drop strip.
    ///   - bottomPadding: The trailing padding below the column.
    ///   - accent: The accent color for selected-state strokes and indicators.
    ///   - dragState: The shared sidebar drag state.
    ///   - dragAutoScrollController: Drives edge auto-scroll during a drag.
    ///   - actions: The host action bundle for selection, reorder, and text.
    public init(
        model: CmuxSidebarProviderRenderModel,
        now: Date,
        selectedWorkspaceId: UUID?,
        tabRowSpacing: CGFloat,
        bottomPadding: CGFloat,
        accent: Color,
        dragState: SidebarDragState,
        dragAutoScrollController: SidebarDragAutoScrollController,
        actions: ExtensionBrowserStackActions
    ) {
        self.model = model
        self.now = now
        self.selectedWorkspaceId = selectedWorkspaceId
        self.tabRowSpacing = tabRowSpacing
        self.bottomPadding = bottomPadding
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

    /// Pure projection of the render model's rows into ordered drop rows for
    /// drag planning, preserving section ids.
    private func dropRows(for model: CmuxSidebarProviderRenderModel) -> [ExtensionSidebarBrowserStackDropRow] {
        model.sections.flatMap { section in
            section.rows.map { row in
                ExtensionSidebarBrowserStackDropRow(
                    workspaceId: row.workspaceId,
                    sectionId: section.id
                )
            }
        }
    }

    public var body: some View {
        let rows = model.sections.flatMap(\.rows)
        let tileRows = model.sections.first { $0.id == "tiles" }?.rows ?? Array(rows.prefix(3))
        let looseRows = model.sections.first { $0.id == "loose" }?.rows ?? Array(rows.dropFirst(3).prefix(5))
        let groupedSections = model.sections.filter { $0.id != "tiles" && $0.id != "loose" && !$0.rows.isEmpty }
        let dropRows = dropRows(for: model)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(stride(from: 0, to: tileRows.count, by: 3)), id: \.self) { rowStart in
                    HStack(spacing: 8) {
                        ForEach(Array(tileRows[rowStart..<min(rowStart + 3, tileRows.count)].enumerated()), id: \.element.id) { offset, row in
                            let index = rowStart + offset
                            ExtensionBrowserStackTileView(
                                row: row,
                                isSelected: row.workspaceId == selectedWorkspaceId
                                    || (selectedWorkspaceId == nil && index == 0),
                                dropRows: dropRows,
                                accent: accent,
                                dragState: dragState,
                                dragAutoScrollController: dragAutoScrollController,
                                actions: actions
                            )
                        }
                        if tileRows.count - rowStart < 3 {
                            ForEach(0..<(3 - (tileRows.count - rowStart)), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(looseRows) { row in
                    ExtensionBrowserStackRowView(
                        row: row,
                        now: now,
                        isSelected: row.workspaceId == selectedWorkspaceId,
                        dropRows: dropRows,
                        accent: accent,
                        dragState: dragState,
                        dragAutoScrollController: dragAutoScrollController,
                        actions: actions
                    )
                }
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(groupedSections) { section in
                    ExtensionBrowserStackGroupView(
                        section: section,
                        now: now,
                        dropRows: dropRows,
                        selectedWorkspaceId: selectedWorkspaceId,
                        accent: accent,
                        dragState: dragState,
                        dragAutoScrollController: dragAutoScrollController,
                        actions: actions
                    )
                }
            }

            Button(action: actions.newTab) {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 22, height: 22)
                    Text(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab", bundle: .main))
                        .font(.system(size: 13, weight: .regular))
                    Spacer(minLength: 0)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab", bundle: .main))

            ExtensionSidebarBrowserStackEmptyArea(
                rowSpacing: tabRowSpacing,
                orderedRows: dropRows,
                dragAutoScrollController: dragAutoScrollController,
                draggedTabId: draggedTabIdBinding,
                dropIndicator: dropIndicatorBinding,
                accent: accent,
                onNewTab: actions.newTab,
                onMove: { move in
                    actions.commitMutation(.moveWorkspace(move))
                }
            )
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(.bottom, bottomPadding)
    }
}
