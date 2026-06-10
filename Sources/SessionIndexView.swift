import AppKit
import Bonsplit
import CMUXAgentVault
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

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

