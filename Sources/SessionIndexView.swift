import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import CMUXAgentLaunch
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

struct SessionIndexView: View {
    @Bindable var store: SessionIndexStore
    /// Lives alongside the store but is owned by this view so drag-state
    /// transitions don't invalidate data-subscribed views elsewhere in the
    /// sidebar.
    @State private var dragCoordinator = SessionDragCoordinator()
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
            DragCancelMonitor(
                isDragActive: { dragCoordinator.draggedKey != nil },
                onCancel: { dragCoordinator.draggedKey = nil }
            )
        )
    }
}

struct AgentIconImage: View, Equatable {
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
            entry.dragItemProvider()
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
            SessionRowMenuItems(entry: entry, onResume: onResume)
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

// MARK: - Session transcript preview

private struct SessionTranscriptPreviewView: View {
    let entry: SessionEntry
    let sizeModel: SessionTranscriptPopoverSizeModel
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

    static func rows(from turns: [SessionTranscriptTurn]) -> [SessionTranscriptDisplayRow] {
        turns.flatMap { turn in
            turn.text.transcriptChunks().enumerated().map { offset, chunk in
                SessionTranscriptDisplayRow(
                    id: "\(turn.id)-\(offset)",
                    role: turn.role,
                    text: chunk,
                    isContinuation: offset > 0
                )
            }
        }
    }
}

private enum SessionTranscriptPreviewState: Equatable {
    case loading
    case missingFile
    case failed
    case loaded([SessionTranscriptDisplayRow])
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
            sizeModel.size = SessionTranscriptPreviewLayout.standard.clamped(proposedSize)
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

// MARK: - Drag payload

extension SessionEntry {
    /// Build the encoded `com.splittabbar.tabtransfer` payload bonsplit's
    /// external-drop decoder accepts for this session.
    ///
    /// The pure value mirrors of bonsplit's `TabItem`/`TabTransferData` live in
    /// `CmuxAppKitSupportUI` (`BonsplitTabItemPayload`/`BonsplitTabTransferPayload`);
    /// this encoder stays app-side because it reads the app `SessionEntry`.
    func tabTransferPayloadData(dragId: UUID) -> Data? {
        let payload = BonsplitTabTransferPayload(
            tab: BonsplitTabItemPayload(
                id: dragId,
                title: displayTitle,
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
        return payload.encoded()
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
    func dragItemProvider() -> NSItemProvider {
        let dragId = SessionDragRegistry.shared.register(self)
        let provider = NSItemProvider()

        if let data = tabTransferPayloadData(dragId: dragId) {
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

        provider.suggestedName = displayTitle
        return provider
    }
}

