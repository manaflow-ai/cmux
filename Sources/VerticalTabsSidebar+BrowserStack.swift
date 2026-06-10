import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Extension browser stack sidebar UI
extension VerticalTabsSidebar {
    func extensionBrowserStackSidebar(
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        let rows = model.sections.flatMap(\.rows)
        let tileRows = model.sections.first { $0.id == "tiles" }?.rows ?? Array(rows.prefix(3))
        let looseRows = model.sections.first { $0.id == "loose" }?.rows ?? Array(rows.dropFirst(3).prefix(5))
        let groupedSections = model.sections.filter { $0.id != "tiles" && $0.id != "loose" && !$0.rows.isEmpty }
        let dropRows = extensionBrowserStackDropRows(for: model)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(stride(from: 0, to: tileRows.count, by: 3)), id: \.self) { rowStart in
                    HStack(spacing: 8) {
                        ForEach(Array(tileRows[rowStart..<min(rowStart + 3, tileRows.count)].enumerated()), id: \.element.id) { offset, row in
                            let index = rowStart + offset
                            extensionBrowserStackTile(
                                row: row,
                                isSelected: row.workspaceId == tabManager.selectedTabId
                                    || (tabManager.selectedTabId == nil && index == 0),
                                dropRows: dropRows
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
                    extensionBrowserStackRow(
                        row: row,
                        now: now,
                        isSelected: row.workspaceId == tabManager.selectedTabId,
                        dropRows: dropRows
                    )
                }
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(groupedSections) { section in
                    extensionBrowserStackGroup(section: section, now: now, dropRows: dropRows)
                }
            }

            Button(action: onNewTab) {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 22, height: 22)
                    Text(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab"))
                        .font(.system(size: 13, weight: .regular))
                    Spacer(minLength: 0)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab"))

            ExtensionSidebarBrowserStackEmptyArea(
                rowSpacing: tabRowSpacing,
                orderedRows: dropRows,
                dragAutoScrollController: dragAutoScrollController,
                draggedTabId: draggedTabIdBinding,
                dropIndicator: dropIndicatorBinding,
                onNewTab: onNewTab,
                onMove: { move in
                    handleExtensionSidebarMutation(.moveWorkspace(move))
                }
            )
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(.bottom, SidebarWorkspaceListMetrics.rowVerticalPadding + 40)
    }

    private func extensionBrowserStackGroup(
        section: CmuxSidebarProviderSection,
        now: Date,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
                Text(extensionSidebarTreeSectionTitle(section.treeSection))
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
                    extensionBrowserStackRow(
                        row: row,
                        now: now,
                        compact: true,
                        isSelected: row.workspaceId == tabManager.selectedTabId,
                        dropRows: dropRows
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

    private func extensionBrowserStackTile(
        row: CmuxSidebarProviderRow,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        let targetRowHeight: CGFloat = 54

        return Button {
            selectExtensionSidebarWorkspace(row.workspaceId)
        } label: {
            extensionBrowserStackIcon(row.leadingIcon, size: 28)
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
            return SidebarTabDragPayload.provider(for: row.workspaceId)
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
                handleExtensionSidebarMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            extensionBrowserStackDropIndicator(row: row, edge: .top)
        }
        .overlay(alignment: .bottom) {
            extensionBrowserStackDropIndicator(row: row, edge: .bottom)
        }
        .contextMenu {
            extensionBrowserStackReorderMenu(row: row)
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    private func extensionBrowserStackRow(
        row: CmuxSidebarProviderRow,
        now: Date,
        compact: Bool = false,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        let targetRowHeight: CGFloat = compact ? 34 : 38

        return Button {
            selectExtensionSidebarWorkspace(row.workspaceId)
        } label: {
            HStack(spacing: 9) {
                extensionBrowserStackIcon(row.leadingIcon, size: compact ? 22 : 24)
                Text(row.title)
                    .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let trailing = extensionSidebarRenderedText(row.trailingText, now: now) {
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
                    .stroke(isSelected ? cmuxAccentColor().opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dragState.draggedTabId == row.workspaceId ? 0.55 : 1)
        .onDrag {
            dragState.beginDragging(tabId: row.workspaceId)
            return SidebarTabDragPayload.provider(for: row.workspaceId)
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
                handleExtensionSidebarMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            extensionBrowserStackDropIndicator(row: row, edge: .top)
        }
        .overlay(alignment: .bottom) {
            extensionBrowserStackDropIndicator(row: row, edge: .bottom)
        }
        .contextMenu {
            extensionBrowserStackReorderMenu(row: row)
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    @ViewBuilder
    private func extensionBrowserStackDropIndicator(
        row: CmuxSidebarProviderRow,
        edge: SidebarDropEdge
    ) -> some View {
        if dragState.dropIndicator == SidebarDropIndicator(tabId: row.workspaceId, edge: edge) {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(height: 2)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func extensionBrowserStackReorderMenu(row: CmuxSidebarProviderRow) -> some View {
        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    private func moveExtensionBrowserStackWorkspace(_ workspaceId: UUID, by delta: Int) {
        let snapshot = extensionSidebarSnapshotForCurrentTabs()
        let model = extensionSidebarRenderModel(snapshot: snapshot, now: Date())
        let dropRows = extensionBrowserStackDropRows(for: model)
        guard let currentIndex = dropRows.firstIndex(where: { $0.workspaceId == workspaceId }) else { return }
        let targetIndex = min(max(currentIndex + delta, 0), dropRows.count - 1)
        guard targetIndex != currentIndex else { return }
        let insertionPosition = delta > 0 ? targetIndex + 1 : targetIndex
        guard let move = extensionBrowserStackMove(
            workspaceId: workspaceId,
            insertionPosition: insertionPosition,
            orderedRows: dropRows
        ) else {
            NSSound.beep()
            return
        }
        guard handleExtensionSidebarMutation(.moveWorkspace(move)) else {
            NSSound.beep()
            return
        }
    }

    private func handleExtensionSidebarMutation(_ mutation: CmuxSidebarProviderMutation) -> Bool {
        let descriptor = CmuxExtensionSidebarSelection.descriptor(for: effectiveExtensionSidebarProviderId)
        guard let provider = CmuxExtensionSidebarSelection.provider(for: descriptor.id) as? any CmuxMutableSidebarProvider else {
            return false
        }
        do {
            let result = try provider.handle(mutation, snapshot: extensionSidebarSnapshotForCurrentTabs())
            if result.ok {
                refreshExtensionSidebarSnapshot()
            }
            return result.ok
        } catch {
#if DEBUG
            cmuxDebugLog("extension.sidebar.mutation.failed provider=\(descriptor.id) error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    private func extensionBrowserStackDropRows(
        for model: CmuxSidebarProviderRenderModel
    ) -> [ExtensionSidebarBrowserStackDropRow] {
        model.sections.flatMap { section in
            section.rows.map { row in
                ExtensionSidebarBrowserStackDropRow(
                    workspaceId: row.workspaceId,
                    sectionId: section.id
                )
            }
        }
    }

    private func extensionBrowserStackMove(
        workspaceId: UUID,
        insertionPosition: Int,
        orderedRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> CmuxSidebarProviderWorkspaceMove? {
        ExtensionSidebarBrowserStackDropPlanner.move(
            draggedWorkspaceId: workspaceId,
            insertionPosition: insertionPosition,
            orderedRows: orderedRows
        )
    }

    private func extensionSidebarWorkspaceSnapshotsById(
        for rows: [CmuxSidebarProviderRow]
    ) -> [UUID: CmuxSidebarProviderWorkspace] {
        var snapshotsById: [UUID: CmuxSidebarProviderWorkspace] = [:]
        for row in rows where snapshotsById[row.workspaceId] == nil {
            snapshotsById[row.workspaceId] = extensionWorkspaceSnapshot(for: row.workspaceId)
        }
        return snapshotsById
    }

    private func extensionBrowserStackIcon(
        _ icon: CmuxSidebarProviderIcon?,
        size: CGFloat
    ) -> some View {
        let shape = icon?.shape ?? .circle
        let foreground = extensionSidebarColor(hex: icon?.foregroundColorHex, fallback: .primary)
        let background = extensionSidebarColor(hex: icon?.backgroundColorHex, fallback: Color.primary.opacity(0.16))
        return ZStack {
            if shape == .circle {
                Circle().fill(background)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(background)
            }
            if let systemImageName = icon?.systemImageName {
                Image(systemName: systemImageName)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundColor(foreground)
            } else {
                Text(icon?.text ?? ".")
                    .font(.system(size: size * 0.58, weight: .bold))
                    .foregroundColor(foreground)
            }
        }
        .frame(width: size, height: size)
    }

    private func extensionSidebarRenderedText(_ text: CmuxSidebarProviderText?, now: Date) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return CmuxExtensionSidebarSelection.localizedText(localized)
        case .relativeDate(let date, _):
            return CmuxExtensionRelativeTimeFormatter.string(from: date, to: now)
        }
    }

    private func extensionSidebarColor(hex: String?, fallback: Color) -> Color {
        guard let hex else { return fallback }
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6 else { return fallback }
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else { return fallback }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    @ViewBuilder
    func extensionSidebarSection(
        _ section: CmuxSidebarProviderSection,
        providerId: String,
        now: Date
    ) -> some View {
        let isCollapsed = collapsedExtensionSidebarSectionIds.contains(section.id)
        let canCreateWorktree = section.treeSection.projectRootPath != nil
        let selectedWorkspaceId = tabManager.selectedTabId
        let workspaceSnapshotsById = extensionSidebarWorkspaceSnapshotsById(for: section.rows)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Button {
                    withAnimation(Self.extensionSidebarDisclosureAnimation) {
                        if isCollapsed {
                            collapsedExtensionSidebarSectionIds.remove(section.id)
                        } else {
                            collapsedExtensionSidebarSectionIds.insert(section.id)
                        }
                    }
                } label: {
                    Image(systemName: isCollapsed ? "folder" : "folder.fill")
                        .font(.system(size: 13, weight: .regular))
                        .offset(y: -0.5)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.toggleSection", defaultValue: "Toggle section"))

                Text(extensionSidebarTreeSectionTitle(section.treeSection))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if canCreateWorktree {
                    Button {
                        createExtensionWorktreeWorkspace(for: section.treeSection)
                    } label: {
                        Image(systemName: extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id) ? "clock" : "plus")
                            .font(.system(size: 11, weight: .regular))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id))
                    .safeHelp(String(localized: "sidebar.extension.createWorktree", defaultValue: "Create worktree"))
                    .accessibilityIdentifier("ExtensionSidebarCreateWorktreeButton.\(section.id)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(section.rows) { row in
                        CmuxExtensionSidebarWorkspaceRowView(
                            row: row,
                            workspace: workspaceSnapshotsById[row.workspaceId],
                            providerId: providerId,
                            relativeNow: now,
                            isSelected: row.workspaceId == selectedWorkspaceId,
                            onSelect: selectExtensionSidebarWorkspace,
                            onOpenWindow: CmuxExtensionSidebarInspectorWindowController.show
                        )
                        .id(row.id)
                        .accessibilityIdentifier("extensionSidebar.workspace.\(row.workspaceId.uuidString)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    func extensionWorkspaceSnapshot(for workspaceId: UUID) -> CmuxSidebarProviderWorkspace? {
        tabManager.tabs.first { $0.id == workspaceId }.map(extensionWorkspaceSnapshot(for:))
    }

    private func extensionSidebarTreeSectionTitle(_ section: CmuxSidebarProviderTreeSection) -> String {
        if let titleText = section.titleText {
            return CmuxExtensionSidebarSelection.localizedText(titleText)
        }
        return section.title
    }

    private func selectExtensionSidebarWorkspace(_ workspaceId: UUID) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        selection = .tabs
        selectedTabIds = [workspaceId]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == workspaceId }
        tabManager.selectWorkspace(workspace)
    }

    private func createExtensionWorktreeWorkspace(for section: CmuxSidebarProviderTreeSection) {
        guard let projectRootPath = section.projectRootPath,
              !extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id) else {
            return
        }

        extensionSidebarWorktreeCreationInFlightSectionIds.insert(section.id)
        Task {
            do {
                let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRootPath)
                let spawnArgs = result.workspaceSpawnArgs()
                tabManager.addWorkspace(
                    title: spawnArgs.title,
                    workingDirectory: spawnArgs.workingDirectory,
                    initialTerminalInput: spawnArgs.initialTerminalInput,
                    inheritWorkingDirectory: spawnArgs.inheritWorkingDirectory,
                    select: true,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: spawnArgs.initialTerminalInput == nil
                )
            } catch {
                NSSound.beep()
#if DEBUG
                cmuxDebugLog("extensionSidebar.worktree.failed project=\(projectRootPath) error=\(error.localizedDescription)")
#endif
            }
            extensionSidebarWorktreeCreationInFlightSectionIds.remove(section.id)
        }
    }

}
