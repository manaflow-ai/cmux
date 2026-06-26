import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CMUXAgentLaunch
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum SessionEntryResumeCoordinator {
    static func resume(_ entry: SessionEntry, tabManager: TabManager) {
        guard let resumeCommand = entry.resumeCommandWithCwd else { return }
        let inputWithReturn = resumeCommand + "\n"
        let targetCwd = entry.resumeWorkingDirectory

        let selected = tabManager.selectedWorkspace
        let selectedTab = tabManager.selectedTabId.flatMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let isRemoteSelection = selectedTab?.isRemoteWorkspace ?? false
        let workspaceCwd = selected?.currentDirectory
        let pwdMatches: Bool = {
            guard !isRemoteSelection,
                  let targetCwd, !targetCwd.isEmpty,
                  let workspaceCwd, !workspaceCwd.isEmpty else { return false }
            let lhs = (targetCwd as NSString).standardizingPath
            let rhs = (workspaceCwd as NSString).standardizingPath
            return lhs == rhs
        }()

        if pwdMatches,
           let workspace = selected,
           let paneId = workspace.bonsplitController.focusedPaneId {
            workspace.newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: targetCwd,
                initialInput: inputWithReturn
            )
            return
        }

        tabManager.addWorkspace(
            workingDirectory: targetCwd,
            initialTerminalInput: inputWithReturn
        )
    }
}

struct SessionIndexView: View {
    @ObservedObject var store: SessionIndexStore
    /// Lives alongside the store but is owned by this view so drag-state
    /// transitions don't invalidate data-subscribed views elsewhere in the
    /// sidebar.
    @StateObject private var dragCoordinator = SessionDragCoordinator()
    /// Sections the user has explicitly collapsed (default is expanded).
    @State private var collapsedSections: Set<SectionKey> = []
    /// Section whose "Show more" popover is currently open.
    @State private var openPopoverSection: SectionKey?
    @State private var previewEntry: SessionEntry?
    let onResume: ((SessionEntry) -> Void)?
    /// Rows shown per section before "Show more" is tapped.
    private static let collapsedRowLimit = 5

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if store.isLoading && store.entries.isEmpty {
                loadingView
            } else if store.entries.isEmpty {
                emptyView
            } else {
                sessionsList
            }
        }
        .onAppear {
            // RightSidebarPanelView's mode toggle also kicks reload() when
            // entries are empty, so guard against the double-reload that
            // would otherwise cancel and restart the in-flight scan.
            if store.entries.isEmpty && !store.isLoading {
                store.reload()
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            ForEach(SessionGrouping.allCases) { mode in
                GroupingButton(
                    mode: mode,
                    isSelected: store.grouping == mode
                ) {
                    if store.grouping != mode {
                        store.grouping = mode
                    }
                }
            }

            Spacer(minLength: 4)

            Toggle(isOn: $store.scopeToCurrentDirectory) {
                Text(String(localized: "sessionIndex.scope.thisFolder", defaultValue: "This folder only"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .frame(height: RightSidebarChromeMetrics.controlHeight)
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(keyPrefix: "rightSidebarSecondaryControl_scope", isVisible: true)
            .disabled(store.currentDirectory == nil)
            .accessibilityIdentifier("SessionScopeToggle.thisFolder")
            .titlebarInteractiveControl()

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "sessionIndex.reload.tooltip", defaultValue: "Reload Vault"))
            .disabled(store.isLoading)
            .titlebarInteractiveControl()
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder()
        .reportRightSidebarChromeGeometryForBonsplitUITest(role: .secondaryBar, isVisible: true, titlebarHeight: RightSidebarChromeMetrics.secondaryBarHeight)
    }

    private var loadingView: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(String(localized: "sessionIndex.loading", defaultValue: "Loading Vault…"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 4) {
            Text(String(localized: "sessionIndex.empty.title", defaultValue: "Vault is empty"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(String(localized: "sessionIndex.empty.subtitle",
                                   defaultValue: "Claude Code, Codex, OpenCode, and Rovo Dev history will appear here."))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionsList: some View {
        let sections = store.sectionsForCurrentGrouping()
        // Read draggedKey once per body eval so every child gets a snapshot
        // of the same value. Children are Equatable value views, so a
        // draggedKey transition only re-renders the two sections whose
        // isDragged flipped — not every section.
        let draggedKey = dragCoordinator.draggedKey

        // Build closure bundles ONCE per render. Every handle the list
        // subtree needs is a closure; the subtree never sees `store` or
        // `dragCoordinator` directly so rows can't observe them.
        let store = self.store
        let dragCoordinator = self.dragCoordinator
        let onResumeClosure = onResume
        let gapActions = SectionGapActions(
            currentDraggedKey: { dragCoordinator.draggedKey },
            moveSection: { key, before in store.moveSection(key, before: before) },
            clearDraggedKey: { dragCoordinator.draggedKey = nil }
        )
        let searchFn: SessionSearchFn = { query, scope, offset, limit in
            await store.searchSessions(query: query, scope: scope, offset: offset, limit: limit)
        }
        let loadSnapshotFn: DirectorySnapshotFn = { cwd in
            await store.loadDirectorySnapshot(cwd: cwd)
        }

        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.key) { index, section in
                    // Drop above this row -> insert dragged section BEFORE this section's key.
                    SectionReorderGap(
                        beforeKey: section.key,
                        isValidDrop: draggedKey == nil || draggedKey != section.key,
                        actions: gapActions
                    ).equatable()
                    IndexSectionView(
                        section: section,
                        rowLimit: Self.collapsedRowLimit,
                        isDragged: draggedKey == section.key,
                        previewEntryId: previewEntry?.id,
                        isCollapsed: Binding(
                            get: { collapsedSections.contains(section.key) },
                            set: { newValue in
                                if newValue {
                                    collapsedSections.insert(section.key)
                                } else {
                                    collapsedSections.remove(section.key)
                                }
                            }
                        ),
                        isPopoverOpen: Binding(
                            get: { openPopoverSection == section.key },
                            set: { newValue in
                                openPopoverSection = newValue ? section.key : nil
                            }
                        ),
                        actions: IndexSectionActions(
                            onBeginDrag: { dragCoordinator.draggedKey = section.key },
                            onPreviewEntry: { entry in
                                previewEntry = entry
                            },
                            onDismissPreview: { id in
                                if previewEntry?.id == id {
                                    previewEntry = nil
                                }
                            },
                            onResume: onResumeClosure,
                            search: searchFn,
                            loadSnapshot: loadSnapshotFn
                        )
                    ).equatable()
                    let _ = index
                }
                // Trailing gap -> append.
                SectionReorderGap(
                    beforeKey: nil,
                    isValidDrop: true,
                    actions: gapActions
                ).equatable()
            }
            .padding(.bottom, 8)
        }
        .modifier(ClearScrollBackground())
        .background(
            DragCancelMonitor(dragCoordinator: dragCoordinator)
        )
    }
}

private struct AgentIconImage: View, Equatable {
    let agent: SessionAgent
    let size: CGFloat

    var body: some View {
        if let assetName = agent.assetName {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: agent.systemImageName ?? "person.crop.circle")
                .font(.system(size: max(size - 2, 10), weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: size, height: size)
        }
    }
}

private struct GroupingButton: View {
    let mode: SessionGrouping
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: mode.symbolName)
                    .symbolRenderingMode(.monochrome)
                    .font(
                        .system(
                            size: RightSidebarChromeControlStyle.secondaryIconSize,
                            weight: RightSidebarChromeControlStyle.iconWeight
                        )
                    )
                Text(mode.label)
                    .font(
                        .system(
                            size: RightSidebarChromeControlStyle.labelSize,
                            weight: RightSidebarChromeControlStyle.labelWeight
                        )
                    )
            }
            .rightSidebarChromePill(isSelected: isSelected, isHovered: isHovered, geometryKeyPrefix: "rightSidebarSecondaryControl_\(mode.rawValue)")
        }
        .buttonStyle(.plain)
        .titlebarInteractiveControl()
        .onHover { isHovered = $0 }
        .help(mode.label)
        .accessibilityIdentifier("SessionGroupingButton.\(mode.rawValue)")
    }
}

/// Closure type for paginated session search. Handed down into the popover
/// instead of a `SessionIndexStore` reference so views inside the lazy list
/// subtree cannot observe the store by accident.
typealias SessionSearchFn = @MainActor (
    _ query: String,
    _ scope: SessionIndexStore.SearchScope,
    _ offset: Int,
    _ limit: Int
) async -> SessionIndexStore.SearchOutcome

/// Closure type for fetching the full merged snapshot of a directory.
/// The popover uses this on the empty-query scroll path so pagination
/// becomes an in-memory slice instead of repeated store round-trips.
typealias DirectorySnapshotFn = @MainActor (_ cwd: String?) async -> DirectorySnapshot

/// Callback bundle handed to `IndexSectionView` in place of a store reference.
/// Every capability the row needs is expressed as a closure so no child view
/// below the snapshot boundary can subscribe to broad store updates;
/// a future `@ObservedObject var store` on a row becomes a type error rather
/// than a silent 100% CPU regression.
struct IndexSectionActions {
    let onBeginDrag: @MainActor () -> Void
    let onPreviewEntry: (SessionEntry) -> Void
    let onDismissPreview: (SessionEntry.ID) -> Void
    let onResume: ((SessionEntry) -> Void)?
    let search: SessionSearchFn
    let loadSnapshot: DirectorySnapshotFn
}

/// Callback bundle for `SectionReorderGap` / `SectionGapDropDelegate`.
struct SectionGapActions {
    let currentDraggedKey: @MainActor () -> SectionKey?
    let moveSection: @MainActor (SectionKey, SectionKey?) -> Void
    let clearDraggedKey: @MainActor () -> Void
}

private struct IndexSectionView: View, Equatable {
    let section: IndexSection
    let rowLimit: Int
    /// True iff this section is the one currently being dragged. Precomputed
    /// in the parent from a single `draggedKey` snapshot so the section's
    /// opacity fade doesn't require observing the drag coordinator here.
    let isDragged: Bool
    let previewEntryId: SessionEntry.ID?
    @Binding var isCollapsed: Bool
    @Binding var isPopoverOpen: Bool
    /// Value-type action bundle. See `IndexSectionActions`; replaces the
    /// earlier `store` / `dragCoordinator` class references so rows can't
    /// observe the store.
    let actions: IndexSectionActions

    /// Skip body re-eval when this view's inputs are unchanged. `actions` is
    /// not comparable (closures) but is expected to be stable (closures
    /// capture stable object references above the list boundary). Excluding
    /// it from `==` is the core optimization that keeps LazyVStack's layout
    /// cache from thrashing when unrelated store fields change.
    static func == (lhs: IndexSectionView, rhs: IndexSectionView) -> Bool {
        lhs.section == rhs.section
            && lhs.rowLimit == rhs.rowLimit
            && lhs.isDragged == rhs.isDragged
            && lhs.previewEntryId == rhs.previewEntryId
            && lhs.isCollapsed == rhs.isCollapsed
            && lhs.isPopoverOpen == rhs.isPopoverOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if !isCollapsed {
                ForEach(Array(section.entries.prefix(rowLimit))) { entry in
                    SessionRow(
                        entry: entry,
                        isPreviewPresented: previewEntryId == entry.id,
                        onPreviewPresentationChange: { isPresented in
                            if isPresented {
                                actions.onPreviewEntry(entry)
                            } else {
                                actions.onDismissPreview(entry.id)
                            }
                        },
                        onResume: actions.onResume
                    )
                        .equatable()
                        .id(entry.id)
                }
                if section.shouldOfferShowMore(rowLimit: rowLimit) {
                    showMoreButton
                }
                Spacer(minLength: 2)
            }
        }
        .opacity(isDragged ? 0.45 : 1.0)
    }

    private var showMoreButton: some View {
        Button {
            isPopoverOpen = true
        } label: {
            Text(String(localized: "sessionIndex.section.showMore", defaultValue: "Show more"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.leading, 32)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            SectionPopoverHost(
                isPresented: $isPopoverOpen,
                section: section,
                search: actions.search,
                loadSnapshot: actions.loadSnapshot,
                onResume: actions.onResume
            )
        )
    }

    private var sectionHeader: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 8) {
                sectionIconView
                Text(section.title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            let beginDrag = actions.onBeginDrag
            DispatchQueue.main.async { beginDrag() }
            return NSItemProvider(object: section.key.raw as NSString)
        } preview: {
            HStack(spacing: 8) {
                sectionIconView
                Text(section.title)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var sectionIconView: some View {
        switch section.icon {
        case .agent(let agent):
            AgentIconImage(agent: agent, size: 14)
        case .folder:
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

private struct SectionReorderGap: View, Equatable {
    /// Section the dragged item should land BEFORE if dropped here. `nil` for
    /// the trailing gap (drop appends to the end of persisted order).
    let beforeKey: SectionKey?
    /// Precomputed in the parent from the single draggedKey snapshot. Keeps
    /// the gap from reading drag state itself.
    let isValidDrop: Bool
    /// Closure bundle — the gap never sees `SessionIndexStore` or
    /// `SessionDragCoordinator` directly, so it cannot `@ObservedObject` them.
    let actions: SectionGapActions
    @State private var isDropTarget: Bool = false

    static func == (lhs: SectionReorderGap, rhs: SectionReorderGap) -> Bool {
        lhs.beforeKey == rhs.beforeKey && lhs.isValidDrop == rhs.isValidDrop
    }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 4)
            .overlay(alignment: .center) {
                if isDropTarget && isValidDrop {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                }
            }
            .onDrop(
                of: [.text],
                delegate: SectionGapDropDelegate(
                    beforeKey: beforeKey,
                    actions: actions,
                    isDropTarget: $isDropTarget
                )
            )
    }
}

private struct SectionGapDropDelegate: DropDelegate {
    let beforeKey: SectionKey?
    let actions: SectionGapActions
    @Binding var isDropTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        guard let dragged = actions.currentDraggedKey() else { return true }
        return dragged != beforeKey
    }

    func dropEntered(info: DropInfo) { isDropTarget = true }
    func dropExited(info: DropInfo) { isDropTarget = false }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        guard let provider = info.itemProviders(for: [.text]).first else {
            actions.clearDraggedKey()
            return false
        }
        let beforeKey = self.beforeKey
        let actions = self.actions
        provider.loadObject(ofClass: NSString.self) { object, _ in
            DispatchQueue.main.async {
                defer { actions.clearDraggedKey() }
                guard let raw = object as? String else { return }
                let key = SectionKey(raw: raw)
                actions.moveSection(key, beforeKey)
            }
        }
        return true
    }
}

private struct SessionRow: View, Equatable {
    let entry: SessionEntry
    let isPreviewPresented: Bool
    let onPreviewPresentationChange: (Bool) -> Void
    let onResume: ((SessionEntry) -> Void)?
    @State private var isHovered: Bool = false

    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        // Skip body re-eval during scroll when the entry is unchanged.
        // The closure isn't compared (it comes from stable parent state).
        lhs.entry == rhs.entry &&
            lhs.isPreviewPresented == rhs.isPreviewPresented
    }

    var body: some View {
        HStack(spacing: 6) {
            AgentIconImage(agent: entry.agent, size: 12)
            Text(entry.displayTitle)
                .font(.system(size: 13))
                .foregroundColor(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(relativeTime(entry.modified))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary.opacity(0.65))
                .fixedSize()
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground)
        .background(previewPopoverHost)
        .onHover { isHovered = $0 }
        .help(helpText)
        .onTapGesture(count: 2) {
            onPreviewPresentationChange(true)
        }
        .onDrag {
            sessionDragItemProvider(for: entry)
        } preview: {
            HStack(spacing: 6) {
                AgentIconImage(agent: entry.agent, size: 12)
                Text(entry.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .contextMenu {
            sessionRowMenuItems(entry: entry, onResume: onResume)
        }
    }

    @ViewBuilder
    private var previewPopoverHost: some View {
        if isPreviewPresented {
            SessionTranscriptPopoverHost(
                isPresented: Binding(
                    get: { isPreviewPresented },
                    set: { onPreviewPresentationChange($0) }
                ),
                entry: entry
            )
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(rowBackgroundColor)
            .padding(.horizontal, 6)
    }

    private var rowBackgroundColor: Color {
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        if isPreviewPresented {
            return Color.primary.opacity(0.07)
        }
        return Color.clear
    }

    private var helpText: String {
        var lines: [String] = [entry.displayTitle]
        if let cwd = entry.cwdLabel {
            lines.append(cwd)
        }
        lines.append(absoluteTime(entry.modified))
        return lines.joined(separator: "\n")
    }

    private func relativeTime(_ date: Date) -> String {
        SessionIndexView.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTime(_ date: Date) -> String {
        SessionIndexView.absoluteFormatter.string(from: date)
    }
}

// MARK: - Shared row actions

/// Right-click menu items for any session row (full or popover). Built as a
/// free `@ViewBuilder` so SessionRow and PopoverRow both attach the same set
/// without duplicating the button list or the action helpers.
@ViewBuilder
private func sessionRowMenuItems(entry: SessionEntry, onResume: ((SessionEntry) -> Void)?) -> some View {
    if let onResume {
        Button {
            onResume(entry)
        } label: {
            Text(String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab"))
        }
        Divider()
    }
    if let url = entry.fileURL {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(String(localized: "sessionIndex.row.open", defaultValue: "Open"))
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Text(String(localized: "sessionIndex.row.reveal", defaultValue: "Reveal in Finder"))
        }
        Divider()
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.path, forType: .string)
        } label: {
            Text(String(localized: "sessionIndex.row.copyPath", defaultValue: "Copy File Path"))
        }
    }
    if let resumeCommand = entry.resumeCommand {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(resumeCommand, forType: .string)
        } label: {
            Text(String(localized: "sessionIndex.row.copyResume", defaultValue: "Copy Resume Command"))
        }
    }
    if let cwd = entry.cwd, !cwd.isEmpty {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        } label: {
            Text(String(localized: "sessionIndex.row.openCwd", defaultValue: "Open Working Directory"))
        }
    }
    if let pr = entry.pullRequest, let url = URL(string: pr.url) {
        Divider()
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(String(localized: "sessionIndex.row.openPR", defaultValue: "Open Pull Request"))
        }
    }
}

// MARK: - Session transcript preview

private struct SessionTranscriptPreviewView: View {
    let entry: SessionEntry
    @ObservedObject var sizeModel: SessionTranscriptPopoverSizeModel
    let onResize: (CGSize) -> Void
    let onDismiss: () -> Void

    @State private var loadState: SessionTranscriptPreviewState = .loading
    @State private var closeIsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: sizeModel.size.width, height: sizeModel.size.height)
        .overlay(alignment: .bottomTrailing) {
            SessionTranscriptResizeHandle(
                size: sizeModel.size,
                onResize: onResize
            )
        }
        .task(id: entry.id) {
            await loadTranscript()
        }
        .background(
            EscapeKeyCatcher { onDismiss() }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentIconImage(agent: entry.agent, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let cwd = entry.cwdLabel {
                    Text(cwd)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(closeIsHovered ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(closeIsHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .onHover { closeIsHovered = $0 }
                .onTapGesture {
                    onDismiss()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(localized: "common.close", defaultValue: "Close")))
                .accessibilityAddTraits(.isButton)
                .help(String(localized: "common.close", defaultValue: "Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            loadingStatusRow
        case .missingFile:
            statusRow(
                systemImage: "doc.badge.questionmark",
                text: String(localized: "sessionIndex.preview.noFile", defaultValue: "No transcript file")
            )
        case .failed:
            statusRow(
                systemImage: "exclamationmark.triangle.fill",
                text: String(localized: "sessionIndex.preview.error", defaultValue: "Couldn't load transcript")
            )
        case .loaded(let turns):
            if turns.isEmpty {
                statusRow(
                    systemImage: "text.bubble",
                    text: String(localized: "sessionIndex.preview.empty", defaultValue: "No previewable messages")
                )
            } else {
                SessionTranscriptVirtualizedList(rows: turns)
            }
        }
    }

    private var loadingStatusRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusRow(systemImage: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @MainActor
    private func loadTranscript() async {
        loadState = .loading
        do {
            let turns = try await SessionTranscriptLoader().load(entry: entry)
            guard !Task.isCancelled else { return }
            loadState = .loaded(SessionTranscriptDisplayRow.rows(from: turns))
        } catch SessionTranscriptLoadError.missingFile {
            guard !Task.isCancelled else { return }
            loadState = .missingFile
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }
}

private enum SessionTranscriptPreviewLayout {
    static let defaultSize = CGSize(width: 520, height: 500)
    static let minSize = CGSize(width: 420, height: 320)
    static let maxSize = CGSize(width: 920, height: 820)

    static func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minSize.width), maxSize.width),
            height: min(max(size.height, minSize.height), maxSize.height)
        )
    }
}

private final class SessionTranscriptPopoverSizeModel: ObservableObject {
    @Published var size: CGSize

    init(size: CGSize = SessionTranscriptPreviewLayout.defaultSize) {
        self.size = size
    }
}

private struct SessionTranscriptResizeHandle: View {
    let size: CGSize
    let onResize: (CGSize) -> Void
    @State private var dragStartSize: CGSize?
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.secondary.opacity(isHovered ? 0.72 : 0.42))
                    .frame(width: CGFloat(6 + index * 5), height: 1)
                    .offset(x: -4, y: CGFloat(-5 - index * 4))
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let baseSize = dragStartSize ?? size
                    dragStartSize = baseSize
                    onResize(
                        CGSize(
                            width: baseSize.width + value.translation.width,
                            height: baseSize.height + value.translation.height
                        )
                    )
                }
                .onEnded { _ in
                    dragStartSize = nil
                }
        )
        .help(String(localized: "sessionIndex.preview.resize", defaultValue: "Resize preview"))
    }
}

private struct SessionTranscriptVirtualizedList: View, Equatable {
    let rows: [SessionTranscriptDisplayRow]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SessionTranscriptTurnView(row: row)
                        .id(row.id)
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color.primary.opacity(0.018))
    }
}

private struct SessionTranscriptTurnView: View, Equatable {
    let row: SessionTranscriptDisplayRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                Text(row.isContinuation ? "" : row.role.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(row.role.foregroundColor)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .trailing)
                if row.isContinuation {
                    Circle()
                        .fill(row.role.foregroundColor.opacity(0.38))
                        .frame(width: 3, height: 3)
                }
            }
            Text(row.text)
                .font(row.role.bodyFont)
                .foregroundColor(.primary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(row.role.foregroundColor.opacity(0.46))
                .frame(width: 2)
        }
        .background(row.role.backgroundColor)
    }
}

private struct SessionTranscriptDisplayRow: Identifiable, Equatable {
    let id: String
    let role: SessionTranscriptRole
    let text: String
    let isContinuation: Bool

    private static let chunkCharacterLimit = 5_000

    static func rows(from turns: [SessionTranscriptTurn]) -> [SessionTranscriptDisplayRow] {
        turns.flatMap { turn in
            chunks(for: turn.text).enumerated().map { offset, chunk in
                SessionTranscriptDisplayRow(
                    id: "\(turn.id)-\(offset)",
                    role: turn.role,
                    text: chunk,
                    isContinuation: offset > 0
                )
            }
        }
    }

    private static func chunks(for text: String) -> [String] {
        guard text.count > chunkCharacterLimit else {
            return [text]
        }
        var output: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let rawEnd = text.index(
                start,
                offsetBy: chunkCharacterLimit,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            let end = preferredBreak(in: text, from: start, rawEnd: rawEnd)
            output.append(String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
        }
        return output.filter { !$0.isEmpty }
    }

    private static func preferredBreak(
        in text: String,
        from start: String.Index,
        rawEnd: String.Index
    ) -> String.Index {
        guard rawEnd < text.endIndex else {
            return text.endIndex
        }
        let searchStart = text.index(
            rawEnd,
            offsetBy: -min(chunkCharacterLimit / 4, text.distance(from: start, to: rawEnd))
        )
        if let newline = text[searchStart..<rawEnd].lastIndex(of: "\n") {
            return text.index(after: newline)
        }
        if let space = text[searchStart..<rawEnd].lastIndex(where: { $0.isWhitespace }) {
            return text.index(after: space)
        }
        return rawEnd
    }
}

private enum SessionTranscriptPreviewState: Equatable {
    case loading
    case missingFile
    case failed
    case loaded([SessionTranscriptDisplayRow])
}

extension SessionEntry {
    /// Whether this entry's on-disk transcript uses Grok's role/type layout.
    /// Read cross-file by `SessionTranscriptLoader`, so it stays `internal`.
    var usesGrokTranscriptLayout: Bool {
        if agent == .grok {
            return true
        }
        guard case .registered(let registration) = specifics else {
            return false
        }
        if case .grokSessionDirectory = registration.sessionIdSource {
            return true
        }
        return false
    }
}

private struct SessionTranscriptPopoverHost: NSViewRepresentable {
    @Binding var isPresented: Bool
    let entry: SessionEntry

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> PopoverAnchorView {
        let view = PopoverAnchorView()
        view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.anchorView = view
        view.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.anchorDidMoveToWindow()
        }
        return view
    }

    func updateNSView(_ nsView: PopoverAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchorView = nsView
        coordinator.update(entry: entry)
        if isPresented {
            coordinator.present()
        } else {
            coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ nsView: PopoverAnchorView, coordinator: Coordinator) {
        nsView.onDidMoveToWindow = nil
        coordinator.dismiss()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool
        weak var anchorView: NSView?

        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?
        private var currentEntry: SessionEntry?
        private let sizeModel = SessionTranscriptPopoverSizeModel()
        private var wantsPresentation = false

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func update(entry: SessionEntry) {
            let shouldRefresh = currentEntry?.id != entry.id
            currentEntry = entry
            if shouldRefresh {
                refreshContent()
            }
        }

        func anchorDidMoveToWindow() {
            guard anchorView?.window != nil else {
                popover?.performClose(nil)
                return
            }
            if wantsPresentation {
                present()
            }
        }

        func present() {
            wantsPresentation = true
            guard let anchorView, anchorView.window != nil else {
                return
            }
            anchorView.superview?.layoutSubtreeIfNeeded()
            let popover = popover ?? makePopover()
            if !popover.isShown {
                refreshContent()
                popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
            }
        }

        func dismiss() {
            wantsPresentation = false
            popover?.performClose(nil)
        }

        func popoverDidClose(_ notification: Notification) {
            wantsPresentation = false
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func refreshContent() {
            guard let entry = currentEntry else { return }
            hostingController.rootView = AnyView(
                SessionTranscriptPreviewView(
                    entry: entry,
                    sizeModel: sizeModel,
                    onResize: { [weak self] proposedSize in
                        self?.resize(to: proposedSize)
                    }
                ) { [weak self] in
                    self?.closeFromContent()
                }
                .id(entry.id)
            )
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            updatePopoverSize()
        }

        private func closeFromContent() {
            isPresented = false
            dismiss()
        }

        private func resize(to proposedSize: CGSize) {
            sizeModel.size = SessionTranscriptPreviewLayout.clamped(proposedSize)
            updatePopoverSize()
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = hostingController
            popover.contentSize = NSSize(width: sizeModel.size.width, height: sizeModel.size.height)
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func updatePopoverSize() {
            popover?.contentSize = NSSize(width: sizeModel.size.width, height: sizeModel.size.height)
        }
    }
}

private final class PopoverAnchorView: NSView {
    var onDidMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
    }
}

/// Invisible AppKit view that fires `onEscape` when Escape is pressed while
/// the popover content is key. Lives in the popover's view tree so it inherits
/// the popover's responder chain.
private struct EscapeKeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = EscapeMonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EscapeMonitorView)?.onEscape = onEscape
    }

    private final class EscapeMonitorView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let win = self.window, win.isKeyWindow else { return event }
                if event.keyCode == 53 {
                    self.onEscape?()
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - "Show more" popover with search

private struct SectionPopoverView: View {
    let section: IndexSection
    /// Closure-typed search handle. The popover never holds a reference to
    /// `SessionIndexStore`; the parent view is the only owner.
    let search: SessionSearchFn
    /// Closure that returns the full merged snapshot for a directory.
    /// Used on the empty-query directory-scope scroll path so pagination
    /// is an in-memory array slice, not repeated store round-trips.
    let loadSnapshot: DirectorySnapshotFn
    let onResume: ((SessionEntry) -> Void)?
    let onDismiss: () -> Void

    @State private var query: String = ""
    @FocusState private var searchFieldFocused: Bool

    /// Rows currently rendered in the popover. In snapshot mode this is a
    /// prefix of `fullSnapshot`; in typed-query mode it's the accumulated
    /// pages from the store.
    @State private var loaded: [SessionEntry] = []
    @State private var hasMore: Bool = true
    @State private var isLoading: Bool = false
    @State private var activeQuery: String = ""
    /// In-flight pagination task for the typed-query path. Reassigned by
    /// `loadMore()`; the previous task is cancelled implicitly. The initial /
    /// query-change load is owned by SwiftUI via `.task(id: query)` and
    /// doesn't use this slot.
    @State private var loadTask: Task<Void, Never>?
    @State private var errorMessages: [String] = []
    /// Full merged snapshot of the directory (empty-query directory scope
    /// only). When non-nil, `loadMore()` slices this array in memory
    /// instead of hitting the store.
    @State private var fullSnapshot: [SessionEntry]?

    private static let pageSize = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                sectionIconView
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(
                    String(localized: "sessionIndex.popover.searchPlaceholder",
                           defaultValue: "Search Vault"),
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFieldFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            if !errorMessages.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(errorMessages, id: \.self) { msg in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.85))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
            }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isLoading && loaded.isEmpty {
                        loadingRow
                    } else if loaded.isEmpty {
                        Text(String(localized: "sessionIndex.popover.noMatches",
                                    defaultValue: "No matches"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(loaded) { entry in
                            PopoverRow(entry: entry) {
                                onResume?(entry)
                                onDismiss()
                            }
                            .equatable()
                        }
                        if hasMore {
                            // Always visible while more pages exist. Serves
                            // as both the "Loading..." indicator and the
                            // pagination sentinel; its .onAppear fires
                            // loadMore() when it scrolls into view.
                            loadingRow
                                .onAppear { loadMore() }
                        } else {
                            Text(String(localized: "sessionIndex.popover.endOfList",
                                        defaultValue: "You've reached the end"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .frame(height: 420)
        }
        // ScrollView is pinned at fixed 420; the outer VStack's natural
        // height (chrome + 420) then drives NSHostingController's
        // preferred content size via sizingOptions. Do NOT pin an outer
        // fixed height; it made SwiftUI center-distribute slack space
        // and squashed the top header padding.
        .frame(width: 360)
        .background(
            EscapeKeyCatcher { onDismiss() }
        )
        // Single SwiftUI-owned lifecycle for the initial load and every
        // query change. `.task(id: query)` auto-cancels on view disappear
        // AND on any `query` change, so we don't need onAppear +
        // onChange + onDisappear + a manual generation counter to
        // discard superseded fetches. The 200ms pause doubles as a
        // debounce: rapid keystrokes bump `id:` which cancels this task
        // before the sleep completes, preventing an unnecessary search.
        .task(id: query) {
            // Any pagination task from the previous query lifecycle is now
            // superseded. Cancel explicitly; reassigning `loadTask =
            // Task { ... }` later doesn't cancel the previous handle on its
            // own, so without this a stale page could still land and
            // append rows that don't match the new query.
            loadTask?.cancel()
            loadTask = nil

            if !searchFieldFocused {
                searchFieldFocused = true
            }

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            activeQuery = trimmed
            errorMessages = []

            if trimmed.isEmpty {
                // Fast first frame: render the scan-time top-N we already
                // have while the full snapshot builds in parallel. On
                // warm cache the snapshot returns immediately and the
                // fast-path rows are replaced in the same tick.
                loaded = section.entries
                hasMore = !section.entries.isEmpty

                // Build-or-return the full directory snapshot. For
                // directory scope scrolling this replaces per-page store
                // fetches with a single merged array + in-memory slice.
                // Agent-scope popovers keep the old paged flow (no
                // snapshot needed, store.entries already top-N per agent).
                if case .directory(let path) = sectionSearchScope {
                    // Keep isLoading=true while the snapshot builds so the
                    // sentinel's onAppear can't race and fire a paged
                    // loadMore() against the store — otherwise we end up
                    // running both the snapshot path AND a paged search in
                    // parallel for the same open (observed in logs as
                    // duplicate session.search.agent lines for the same
                    // cwd, followed by session.search.total offset=N).
                    isLoading = true
                    let snapshot = await loadSnapshot(path)
                    guard !Task.isCancelled else { return }
                    fullSnapshot = snapshot.entries
                    // Show the first page's worth immediately; loadMore
                    // grows `loaded` from the snapshot on scroll.
                    let initialWindow = min(Self.pageSize, snapshot.entries.count)
                    loaded = Array(snapshot.entries.prefix(initialWindow))
                    hasMore = initialWindow < snapshot.entries.count
                    errorMessages = snapshot.errors
                    isLoading = false
                } else {
                    fullSnapshot = nil
                    isLoading = false
                }
                return
            }

            // Typed query — drop any prior snapshot and run a paged
            // search instead. Cancellation-sensitive debounce: rapid
            // keystrokes bump id: and SwiftUI cancels before the search
            // fires.
            fullSnapshot = nil
            loaded = []
            hasMore = true
            isLoading = true

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            let outcome = await search(trimmed, sectionSearchScope, 0, Self.pageSize)
            guard !Task.isCancelled else { return }
            applyOutcome(outcome, append: false)
        }
        .onDisappear {
            // .task(id: query) auto-cancels on disappear, but the
            // separate loadTask slot (used by loadMore) is ours to
            // manage. Cancel it so a fetch in flight when the popover
            // closes doesn't keep running to completion.
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Append the next page to `loaded`. Triggered by the sentinel row's
    /// onAppear. In snapshot mode (empty-query directory scope) this is a
    /// pure in-memory array slice with zero store calls. In typed-query mode
    /// it fires a paged search. Explicitly cancels any earlier load-more
    /// still in flight so a superseded page can't append stale rows after
    /// a query change.
    private func loadMore() {
        guard !isLoading, hasMore else { return }

        if let snapshot = fullSnapshot {
            let next = min(loaded.count + Self.pageSize, snapshot.count)
            loaded = Array(snapshot.prefix(next))
            hasMore = next < snapshot.count
            return
        }

        isLoading = true
        let scope = sectionSearchScope
        let search = self.search
        let query = activeQuery
        let offset = loaded.count
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            let outcome = await search(query, scope, offset, Self.pageSize)
            guard !Task.isCancelled else { return }
            applyOutcome(outcome, append: true)
        }
    }

    /// Merge a fetch result into the popover's display state. Both the
    /// initial-page and load-more paths converge here so the count/hasMore/
    /// error/loading bookkeeping lives in one place.
    @MainActor
    private func applyOutcome(_ outcome: SessionIndexStore.SearchOutcome, append: Bool) {
        // `append` is only reached from the paged path (typed query or
        // agent scope). In both cases `offset = loaded.count` is
        // monotonic against the store's ordering, so raw-append is
        // correct. The empty-query directory case uses the snapshot
        // path and never reaches here.
        //
        // Earlier revisions of this method dedup-filtered outcome.entries
        // on entry.id; with `hasMore = outcome.entries.count >=
        // pageSize` and `offset = loaded.count`, filtering caused
        // loaded.count to advance more slowly than the raw page size,
        // which kept hasMore perpetually true and re-requested the
        // same window. Removing the dedup makes the cursor match the
        // page boundaries the store actually returns.
        if append {
            loaded.append(contentsOf: outcome.entries)
        } else {
            loaded = outcome.entries
        }
        hasMore = outcome.entries.count >= Self.pageSize
        errorMessages = outcome.errors
        isLoading = false
    }

    private var sectionSearchScope: SessionIndexStore.SearchScope {
        let raw = section.key.raw
        if raw.hasPrefix("agent:"),
           let agent = SessionAgent(rawValue: String(raw.dropFirst("agent:".count))) {
            return .agent(agent)
        }
        if raw.hasPrefix("dir:") {
            let path = String(raw.dropFirst("dir:".count))
            return .directory(path.isEmpty ? nil : path)
        }
        return .directory(nil)
    }

    @ViewBuilder
    private var sectionIconView: some View {
        switch section.icon {
        case .agent(let agent):
            AgentIconImage(agent: agent, size: 14)
        case .folder:
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

private struct PopoverRow: View, Equatable {
    let entry: SessionEntry
    let onActivate: () -> Void

    @State private var isHovered: Bool = false

    static func == (lhs: PopoverRow, rhs: PopoverRow) -> Bool {
        lhs.entry == rhs.entry
    }

    fileprivate static func flatten(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\r\n", with: " ")
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "\r", with: " ")
        out = out.replacingOccurrences(of: "\t", with: " ")
        return out
    }

    fileprivate static func refreshInterval(for modified: Date, now: Date = .now) -> TimeInterval {
        let age = max(0, now.timeIntervalSince(modified))
        if age < 3_600 { return 60 }
        if age < 86_400 { return 3_600 }
        return 86_400
    }

    @ViewBuilder
    private var modifiedText: some View {
        TimelineView(RelativeTimestampSchedule(modified: entry.modified)) { context in
            Text(SessionIndexView.relativeFormatter.localizedString(for: entry.modified, relativeTo: context.date))
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundColor(.secondary.opacity(0.7))
        .fixedSize()
    }

    var body: some View {
        HStack(spacing: 6) {
            AgentIconImage(agent: entry.agent, size: 12)
            // Flatten newlines so titles containing `<command-message>…\n…`
            // envelopes stay single-line; SwiftUI's `lineLimit(1)` doesn't
            // always constrain a Text that has hard line breaks in the
            // source string.
            Text(Self.flatten(entry.displayTitle))
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            modifiedText
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onActivate() }
        .onDrag {
            sessionDragItemProvider(for: entry)
        }
        .help(entry.cwdLabel ?? entry.displayTitle)
        .contextMenu {
            sessionRowMenuItems(entry: entry, onResume: { _ in onActivate() })
        }
    }
}

private struct RelativeTimestampSchedule: TimelineSchedule {
    let modified: Date

    func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(current: startDate, modified: modified)
    }

    struct Entries: Sequence, IteratorProtocol {
        var current: Date
        let modified: Date

        mutating func next() -> Date? {
            let date = current
            current = current.addingTimeInterval(PopoverRow.refreshInterval(for: modified, now: date))
            return date
        }
    }
}

// MARK: - Drag payload

/// Mirrors `Bonsplit.TabItem`'s Codable shape so we can produce a JSON payload
/// that bonsplit's external-drop path will decode and accept.
private struct MirrorTabItem: Codable {
    let id: UUID
    let title: String
    let hasCustomTitle: Bool
    let icon: String?
    let iconImageData: Data?
    let kind: String?
    let isDirty: Bool
    let showsNotificationBadge: Bool
    let isLoading: Bool
    let isAudioMuted: Bool
    let isPinned: Bool
}

/// Mirrors `Bonsplit.TabTransferData` exactly.
private struct MirrorTabTransferData: Codable {
    let tab: MirrorTabItem
    let sourcePaneId: UUID
    let sourceProcessId: Int32
}

/// Build the encoded payload bonsplit's external-drop decoder accepts.
private func sessionTabTransferData(for entry: SessionEntry, dragId: UUID) -> Data? {
    let mirror = MirrorTabTransferData(
        tab: MirrorTabItem(
            id: dragId,
            title: entry.displayTitle,
            hasCustomTitle: false,
            icon: "terminal.fill",
            iconImageData: nil,
            kind: "terminal",
            isDirty: false,
            showsNotificationBadge: false,
            isLoading: false,
            isAudioMuted: false,
            isPinned: false
        ),
        sourcePaneId: UUID(),
        sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
    )
    return try? JSONEncoder().encode(mirror)
}

/// NSItemProvider used by `.onDrag {}`. Registers ONLY
/// `com.splittabbar.tabtransfer` so the terminal's NSDraggingDestination
/// (which accepts `.string` / `public.utf8-plain-text`) is not hit-tested
/// for our drag. With the terminal out of the way, bonsplit's SwiftUI
/// `.onDrop(of: [.tabTransfer])` overlay can render the blue insert/split
/// zones across the entire pane (including its center).
///
/// Also mirrors the encoded blob onto NSPasteboard(name: .drag) since
/// bonsplit's external-drop decoder reads from that pasteboard directly
/// and SwiftUI's NSItemProvider bridge doesn't always surface custom
/// UTTypes there reliably.
@MainActor
private func sessionDragItemProvider(for entry: SessionEntry) -> NSItemProvider {
    let dragId = SessionDragRegistry.shared.register(entry)
    let provider = NSItemProvider()

    if let data = sessionTabTransferData(for: entry, dragId: dragId) {
        provider.registerDataRepresentation(
            forTypeIdentifier: "com.splittabbar.tabtransfer",
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        let pb = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
        pb.addTypes([type], owner: nil)
        pb.setData(data, forType: type)
    }

    provider.suggestedName = entry.displayTitle
    return provider
}

// MARK: - NSPopover host

/// Hosts SectionPopoverView in a real NSPopover. SwiftUI's native `.popover()`
/// doesn't reliably let the embedded TextField become first responder in cmux's
/// focus-managed environment because the terminal keeps grabbing focus back.
struct SectionPopoverHost: NSViewRepresentable {
    @Binding var isPresented: Bool
    let section: IndexSection
    /// Closure-typed search handle passed through to the SwiftUI popover
    /// body. The host no longer holds a `SessionIndexStore` reference.
    let search: SessionSearchFn
    let loadSnapshot: DirectorySnapshotFn
    let onResume: ((SessionEntry) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchorView = nsView
        coordinator.update(
            section: section,
            search: search,
            loadSnapshot: loadSnapshot,
            onResume: onResume
        )
        if isPresented {
            coordinator.present()
        } else {
            coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool
        weak var anchorView: NSView?
        private(set) var debugRefreshContentCallCount = 0
        var debugIsPopoverShown: Bool { popover?.isShown == true }

        private let hostingController: NSHostingController<AnyView> = {
            NSHostingController(rootView: AnyView(EmptyView()))
            // DO NOT set sizingOptions here. sizingOptions =
            // [.preferredContentSize] makes NSHostingController
            // continuously rewrite its preferredContentSize from SwiftUI
            // layout; NSPopover observes preferredContentSize and will
            // override any manual popover.contentSize we set. On first
            // open SwiftUI layout settles over multiple passes and
            // preferredContentSize briefly reports a partial height —
            // NSPopover latches onto that and renders squished (evidence:
            // /tmp/cmux-debug-spin-fix.log, refreshContent logged
            // fitting=360x486 at present, but visible popover was ~280).
            // Instead we drive popover.contentSize manually from
            // fittingSize on every updateNSView / present call.
        }()
        private var popover: NSPopover?
        private var currentSection: IndexSection?
        private var currentSearch: SessionSearchFn?
        private var currentLoadSnapshot: DirectorySnapshotFn?
        private var currentOnResume: ((SessionEntry) -> Void)?
        private var lastRenderedSection: IndexSection?
        private var lastRenderedPresentationCount: Int?
        /// Bumped on every present(). Used as the SwiftUI view identity so each
        /// open gets fresh view-local state.
        private var presentationCount = 0

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func update(
            section: IndexSection,
            search: @escaping SessionSearchFn,
            loadSnapshot: @escaping DirectorySnapshotFn,
            onResume: ((SessionEntry) -> Void)?
        ) {
            currentSection = section
            currentSearch = search
            currentLoadSnapshot = loadSnapshot
            currentOnResume = onResume
            // When hidden, defer rebuilding the hosting view until `present()`.
            // Rewriting rootView + forcing layout on every parent re-render was
            // the 100% CPU loop behind #3010.
            guard popover?.isShown == true else { return }
            // Rows capture stable closure bundles above the list boundary, so
            // the section snapshot is the meaningful input here. Skipping
            // identical visible-section updates avoids re-laying out the popover
            // during unrelated parent re-renders while still refreshing when the
            // visible content actually changes.
            guard lastRenderedSection != section || lastRenderedPresentationCount != presentationCount else { return }
            refreshContent()
        }

        private func refreshContent() {
            guard let section = currentSection,
                  let search = currentSearch,
                  let loadSnapshot = currentLoadSnapshot else { return }
            debugRefreshContentCallCount += 1
            let onResume = currentOnResume
            let identity = presentationCount
            hostingController.rootView = AnyView(
                SectionPopoverView(
                    section: section,
                    search: search,
                    loadSnapshot: loadSnapshot,
                    onResume: onResume
                ) { [weak self] in
                    self?.closeFromContent()
                }
                // Tied to presentationCount so reopening the popover discards
                // the prior open's view-local search and scroll state.
                .id(identity)
            )
            lastRenderedSection = section
            lastRenderedPresentationCount = presentationCount
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            updateContentSize()
        }

        func present() {
            guard let anchorView, anchorView.window != nil else {
                isPresented = false
                return
            }
            anchorView.superview?.layoutSubtreeIfNeeded()
            let popover = popover ?? makePopover()
            // Only bump identity on a hidden-to-shown transition. Bumping on every
            // updateNSView (which fires on parent re-renders, e.g. ObservedObject
            // store changes) would reset SectionPopoverView's view-local state
            // on every tick.
            if !popover.isShown {
                presentationCount += 1
                refreshContent()
            }
            updateContentSize()
            guard !popover.isShown else { return }
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
        }

        func dismiss() {
            popover?.performClose(nil)
        }

        func closeFromContent() {
            isPresented = false
            dismiss()
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            p.contentViewController = hostingController
            p.delegate = self
            self.popover = p
            return p
        }

        private func updateContentSize() {
            let fitting = hostingController.view.fittingSize
            guard fitting.width > 0, fitting.height > 0 else { return }
            popover?.contentSize = NSSize(
                width: ceil(max(fitting.width, 360)),
                height: ceil(min(fitting.height, 480))
            )
        }
    }
}

// MARK: - Drag cancel monitor

/// Clears `dragCoordinator.draggedKey` after any mouseUp OR Escape keypress,
/// so a cancelled drag (user releases outside any valid drop target, or
/// presses Esc mid-drag) doesn't leave the section stuck at 0.45 opacity.
/// Successful drops clear the key themselves via
/// `SectionGapDropDelegate.performDrop` and that clear happens under
/// `DispatchQueue.main.async`, so the drop path always wins the race
/// against this fallback.
private struct DragCancelMonitor: NSViewRepresentable {
    let dragCoordinator: SessionDragCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = DragCancelMonitorView()
        view.dragCoordinator = dragCoordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragCancelMonitorView)?.dragCoordinator = dragCoordinator
    }

    private final class DragCancelMonitorView: NSView {
        weak var dragCoordinator: SessionDragCoordinator?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            // Cover every way a drag can end without a drop firing:
            // mouse release (default cancellation) and Escape (AppKit
            // signals drag abort by delivering a keyDown with
            // kVK_Escape / keyCode 53). Without the Escape branch,
            // pressing Esc to cancel a section drag leaves the section
            // stuck at 0.45 opacity until the next mouseUp elsewhere.
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .otherMouseUp, .keyDown]
            ) { [weak self] event in
                guard let coordinator = self?.dragCoordinator,
                      coordinator.draggedKey != nil else { return event }
                if event.type == .keyDown, event.keyCode != 53 { // 53 = kVK_Escape
                    return event
                }
                // Defer the clear so any `performDrop` already queued on the
                // main actor wins first; this path only matters when no drop
                // fires, i.e. the drag was cancelled.
                DispatchQueue.main.async {
                    coordinator.draggedKey = nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
