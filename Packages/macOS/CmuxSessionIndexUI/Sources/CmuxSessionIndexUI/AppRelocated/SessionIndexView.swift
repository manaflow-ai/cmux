import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSessionIndex
import CmuxSessionIndexUI
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

// `SessionSearchFn` and `DirectorySnapshotFn` moved to CmuxSessionIndexUI
// (Popover/SessionPopoverSearchSeam.swift), spelled in package terms
// (`SearchScope`/`SearchOutcome`/`DirectorySnapshot`). The app builds the closures
// from `SessionIndexStore` and injects them through `SectionPopoverHost`.

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
                    let isPreviewPresented = previewEntryId == entry.id
                    SessionRow(
                        entry: entry,
                        displayTitle: entry.displayTitle,
                        agentAssetName: entry.agent.assetName,
                        agentSystemImageName: entry.agent.systemImageName,
                        helpText: entry.sessionRowHelpText(displayTitle: entry.displayTitle),
                        isPreviewPresented: isPreviewPresented,
                        onPreviewPresentationChange: { isPresented in
                            if isPresented {
                                actions.onPreviewEntry(entry)
                            } else {
                                actions.onDismissPreview(entry.id)
                            }
                        },
                        dragItemProvider: { sessionDragItemProvider(for: entry) },
                        previewHost: {
                            SessionTranscriptPopoverHost(
                                isPresented: Binding(
                                    get: { isPreviewPresented },
                                    set: { isPresented in
                                        if isPresented {
                                            actions.onPreviewEntry(entry)
                                        } else {
                                            actions.onDismissPreview(entry.id)
                                        }
                                    }
                                ),
                                entry: entry
                            )
                        },
                        menuContent: {
                            SessionRowMenu(entry: entry, onResume: actions.onResume)
                        }
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
            AgentIconImage(assetName: agent.assetName, systemImageName: agent.systemImageName, size: 14)
        case .folder:
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

// MARK: - Shared row actions

/// Right-click menu items for any session row (full or popover). A scoped `View`
/// struct so SessionRow and PopoverRow both attach the same set without
/// duplicating the button list or the action helpers. Stays app-side because the
/// buttons reach NSWorkspace/NSPasteboard and resolve app-bundle localization.
struct SessionRowMenu: View {
    let entry: SessionEntry
    let onResume: ((SessionEntry) -> Void)?

    var body: some View {
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
}

// MARK: - Session transcript preview
//
// The transcript preview SwiftUI subtree (SessionTranscriptPreviewView, its rows,
// resize handle, layout, preview state, size model, and EscapeKeyCatcher) now lives in
// CmuxSessionIndexUI/Transcript. This host stays app-side: it owns the AppKit NSPopover,
// resolves the app-bundle localization + presentation (agent icon, title, cwd, status
// strings, role labels, loader markers), and constructs the package view with those
// already-resolved values plus the injected SessionIndexStore.ripgrepScanner.

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

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool
        weak var anchorView: NSView?

        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?
        private var currentEntry: SessionEntry?
        private let layout = SessionTranscriptPreviewLayout.standard
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
            // Resolve all app-bundle localization and presentation here, then hand the
            // package view already-resolved values + the injected scanner. The status
            // strings, role labels, and loader markers must resolve against the app
            // bundle (the package bundle lacks these keys).
            let strings = SessionTranscriptPreviewStrings(
                close: String(localized: "common.close", defaultValue: "Close"),
                resize: String(localized: "sessionIndex.preview.resize", defaultValue: "Resize preview"),
                loading: String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…"),
                noFile: String(localized: "sessionIndex.preview.noFile", defaultValue: "No transcript file"),
                error: String(localized: "sessionIndex.preview.error", defaultValue: "Couldn't load transcript"),
                empty: String(localized: "sessionIndex.preview.empty", defaultValue: "No previewable messages"),
                roleLabel: { role in role.label }
            )
            hostingController.rootView = AnyView(
                SessionTranscriptPreviewView(
                    entry: entry,
                    assetName: entry.agent.assetName,
                    systemImageName: entry.agent.systemImageName,
                    title: entry.displayTitle,
                    cwdLabel: entry.cwdLabel,
                    strings: strings,
                    ripgrepScanner: SessionIndexStore.ripgrepScanner,
                    truncatedMarker: String(localized: "sessionIndex.preview.truncated", defaultValue: "Preview truncated"),
                    largeRecordMarker: String(localized: "sessionIndex.preview.largeRecord", defaultValue: "Large transcript record omitted"),
                    layout: layout,
                    sizeModel: sizeModel,
                    onResize: { [weak self] proposedSize in
                        self?.resize(to: proposedSize)
                    },
                    onDismiss: { [weak self] in
                        self?.closeFromContent()
                    }
                )
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
            sizeModel.size = layout.clamped(proposedSize)
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

// MARK: - "Show more" popover with search
//
// `SectionPopoverView`, `SessionSearchFn`, and `DirectorySnapshotFn` moved to
// CmuxSessionIndexUI (Popover/). The app-side `SectionPopoverHost` (below) hosts the
// package view in a real NSPopover and injects the app-only seams: the resolved
// row title (`SessionEntry.displayTitle`), the resolved agent icon names
// (`SessionAgent` presentation extension), the drag payload factory
// (`sessionDragItemProvider`), and the shared right-click menu (`SessionRowMenu`).

// `SessionRow`, `PopoverRow`, and `RelativeTimestampSchedule` were moved to
// `CmuxSessionIndexUI` (Rows/SessionRow.swift + Rows/PopoverRow.swift +
// Rows/RelativeTimestampSchedule.swift). The drag-payload factory
// (`sessionDragItemProvider`), shared menu view (`SessionRowMenu`), and the
// transcript-preview popover host (`SessionTranscriptPopoverHost`, an AppKit
// `NSViewRepresentable`) stay app-side and are injected into the package rows as the
// `dragItemProvider` / `menuContent` / `previewHost` closures at the call sites in
// `IndexSectionView` and `SectionPopoverView`. Both rows resolve relative time
// themselves via the package's `RelativeTimestampSchedule`; the row's hover tooltip
// is composed by the package's `SessionEntry.sessionRowHelpText(displayTitle:)`
// (Rows/SessionEntry+SessionRowPresentation.swift), with the app passing the
// app-resolved `displayTitle`.

// MARK: - Drag payload

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
    // TODO(refactor): `SessionDragRegistry.shared` was removed when the registry
    // was de-singletonized into a constructor-injected owner held at the app
    // composition root (`Sources/SessionDragRegistry.swift`). This producer must
    // switch to the injected owner (e.g. an injected `sessionDragRegistry`
    // reached from the Sessions sidebar's environment/owner). Left dangling
    // intentionally: forbidden/reader file; the orchestrator wires the owner.
    let dragId = SessionDragRegistry.shared.register(entry)
    let provider = NSItemProvider()
    // Resolve the app-localized display title once; the package payload factory
    // never calls `String(localized:)` so the title must be passed in.
    let title = entry.displayTitle

    if let data = MirrorTabTransferData.encoded(title: title, dragId: dragId) {
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

    provider.suggestedName = title
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
                    onResume: onResume,
                    // App-resolved seams: the package popover reaches no app-side
                    // presentation/registry. The chrome strings, `displayTitle`, and the
                    // agent icon names bind against the app bundle / asset catalog; the
                    // drag factory and the shared right-click menu reach NSWorkspace/NSPasteboard.
                    strings: SectionPopoverStrings(
                        searchPlaceholder: String(
                            localized: "sessionIndex.popover.searchPlaceholder",
                            defaultValue: "Search Vault"
                        ),
                        noMatches: String(
                            localized: "sessionIndex.popover.noMatches",
                            defaultValue: "No matches"
                        ),
                        endOfList: String(
                            localized: "sessionIndex.popover.endOfList",
                            defaultValue: "You've reached the end"
                        ),
                        loading: String(
                            localized: "sessionIndex.popover.loading",
                            defaultValue: "Loading…"
                        )
                    ),
                    displayTitle: { entry in entry.displayTitle },
                    agentIcon: { agent in
                        AgentIconPresentation(
                            assetName: agent.assetName,
                            systemImageName: agent.systemImageName
                        )
                    },
                    dragItemProvider: { entry in sessionDragItemProvider(for: entry) },
                    menuContent: { [weak self] entry in
                        SessionRowMenu(
                            entry: entry,
                            onResume: { resumed in
                                onResume?(resumed)
                                self?.closeFromContent()
                            }
                        )
                    },
                    onDismiss: { [weak self] in
                        self?.closeFromContent()
                    }
                )
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
