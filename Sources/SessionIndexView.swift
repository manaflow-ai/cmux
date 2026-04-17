import AppKit
import Bonsplit
import SwiftUI
import UniformTypeIdentifiers

struct SessionIndexView: View {
    @ObservedObject var store: SessionIndexStore
    /// Sections the user has explicitly collapsed (default is expanded).
    @State private var collapsedSections: Set<SectionKey> = []
    /// Section whose "Show more" popover is currently open.
    @State private var openPopoverSection: SectionKey? = nil
    let onResume: ((SessionEntry) -> Void)?

    /// Rows shown per section before "Show more" is tapped.
    private static let collapsedRowLimit = 5

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if store.isLoading && store.entries.isEmpty {
                loadingView
            } else if store.entries.isEmpty {
                emptyView
            } else {
                sessionsList
            }
        }
        .onAppear {
            if store.entries.isEmpty {
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
            .disabled(store.currentDirectory == nil)

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "sessionIndex.reload.tooltip", defaultValue: "Reload sessions"))
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 29)
    }

    private var loadingView: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(String(localized: "sessionIndex.loading", defaultValue: "Scanning sessions…"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 4) {
            Text(String(localized: "sessionIndex.empty.title", defaultValue: "No sessions found"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(String(localized: "sessionIndex.empty.subtitle",
                                   defaultValue: "Sessions from Claude Code, Codex, and OpenCode will appear here."))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionsList: some View {
        let sections = store.sectionsForCurrentGrouping()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.key) { index, section in
                    SectionReorderGap(insertIndex: index, store: store)
                    IndexSectionView(
                        section: section,
                        rowLimit: Self.collapsedRowLimit,
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
                        store: store,
                        onResume: onResume
                    )
                }
                SectionReorderGap(insertIndex: sections.count, store: store)
            }
            .padding(.bottom, 8)
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
                    .font(.system(size: 10, weight: .medium))
                Text(mode.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10)
                          : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(mode.label)
    }
}

private struct IndexSectionView: View {
    let section: IndexSection
    let rowLimit: Int
    @Binding var isCollapsed: Bool
    @Binding var isPopoverOpen: Bool
    @ObservedObject var store: SessionIndexStore
    let onResume: ((SessionEntry) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if !isCollapsed {
                if section.entries.isEmpty {
                    Text(String(localized: "sessionIndex.section.noChats", defaultValue: "No chats"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.leading, 32)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(section.entries.prefix(rowLimit))) { entry in
                        SessionRow(entry: entry, onResume: onResume)
                            .equatable()
                    }
                    if section.entries.count > rowLimit {
                        showMoreButton
                    }
                }
                Spacer(minLength: 2)
            }
        }
        .opacity(store.draggedKey == section.key ? 0.45 : 1.0)
    }

    private var showMoreButton: some View {
        Button {
            isPopoverOpen = true
        } label: {
            Text(String(localized: "sessionIndex.section.showMore", defaultValue: "Show more"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.leading, 32)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            SectionPopoverHost(
                isPresented: $isPopoverOpen,
                section: section,
                store: store,
                onResume: onResume
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            DispatchQueue.main.async { store.draggedKey = section.key }
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
            Image(agent.assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
        case .folder:
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

private struct SectionReorderGap: View {
    let insertIndex: Int
    @ObservedObject var store: SessionIndexStore
    @State private var isDropTarget: Bool = false

    var body: some View {
        let isValid = isValidDrop
        Rectangle()
            .fill(Color.clear)
            .frame(height: 4)
            .overlay(alignment: .center) {
                if isDropTarget && isValid {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                }
            }
            .onDrop(
                of: [.text],
                delegate: SectionGapDropDelegate(
                    insertIndex: insertIndex,
                    store: store,
                    isDropTarget: $isDropTarget
                )
            )
    }

    private var isValidDrop: Bool {
        guard let dragged = store.draggedKey,
              let oldIndex = store.currentIndex(of: dragged) else {
            return true
        }
        return insertIndex != oldIndex && insertIndex != oldIndex + 1
    }
}

private struct SectionGapDropDelegate: DropDelegate {
    let insertIndex: Int
    let store: SessionIndexStore
    @Binding var isDropTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        guard let dragged = store.draggedKey,
              let oldIndex = store.currentIndex(of: dragged) else {
            return true
        }
        return insertIndex != oldIndex && insertIndex != oldIndex + 1
    }

    func dropEntered(info: DropInfo) { isDropTarget = true }
    func dropExited(info: DropInfo) { isDropTarget = false }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        guard let provider = info.itemProviders(for: [.text]).first else {
            store.draggedKey = nil
            return false
        }
        let storedInsert = insertIndex
        provider.loadObject(ofClass: NSString.self) { object, _ in
            DispatchQueue.main.async {
                defer { store.draggedKey = nil }
                guard let raw = object as? String else { return }
                let key = SectionKey(raw: raw)
                guard let oldIndex = store.currentIndex(of: key) else { return }
                let target = storedInsert > oldIndex ? storedInsert - 1 : storedInsert
                store.moveSection(key, toInsertIndex: target)
            }
        }
        return true
    }
}

private struct SessionRow: View, Equatable {
    let entry: SessionEntry
    let onResume: ((SessionEntry) -> Void)?
    @State private var isHovered: Bool = false

    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        // Skip body re-eval during scroll when the entry is unchanged.
        // The closure isn't compared (it comes from stable parent state).
        lhs.entry == rhs.entry
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(entry.agent.assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 12, height: 12)
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
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { isHovered = $0 }
        .help(helpText)
        .onTapGesture(count: 2) {
            if let onResume { onResume(entry) }
        }
        .onDrag {
            sessionDragItemProvider(for: entry)
        } preview: {
            HStack(spacing: 6) {
                Image(entry.agent.assetName)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
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
            if let onResume {
                Button {
                    onResume(entry)
                } label: {
                    Text(String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab"))
                }
                Divider()
            }
            if entry.fileURL != nil {
                Button {
                    open()
                } label: {
                    Text(String(localized: "sessionIndex.row.open", defaultValue: "Open"))
                }
                Button {
                    revealInFinder()
                } label: {
                    Text(String(localized: "sessionIndex.row.reveal", defaultValue: "Reveal in Finder"))
                }
                Divider()
                Button {
                    copyPath()
                } label: {
                    Text(String(localized: "sessionIndex.row.copyPath", defaultValue: "Copy File Path"))
                }
            }
            Button {
                copyResumeCommand()
            } label: {
                Text(String(localized: "sessionIndex.row.copyResume", defaultValue: "Copy Resume Command"))
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

    private var helpText: String {
        var lines: [String] = [entry.displayTitle]
        if let cwd = entry.cwdLabel {
            lines.append(cwd)
        }
        lines.append(absoluteTime(entry.modified))
        return lines.joined(separator: "\n")
    }

    private func open() {
        guard let url = entry.fileURL else {
            if let cwd = entry.cwd, !cwd.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url = entry.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath() {
        guard let url = entry.fileURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
    }

    private func copyResumeCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.resumeCommand, forType: .string)
    }

    private func relativeTime(_ date: Date) -> String {
        SessionIndexView.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}


// MARK: - "Show more" popover with search

private struct SectionPopoverView: View {
    let section: IndexSection
    let store: SessionIndexStore
    let onResume: ((SessionEntry) -> Void)?
    let onDismiss: () -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    /// Pages of results loaded so far. Each page is `pageSize` rows from the store's
    /// paginated search.
    @State private var loaded: [SessionEntry] = []
    @State private var hasMore: Bool = true
    @State private var isLoading: Bool = false
    @State private var activeQuery: String = ""
    @State private var loadTask: Task<Void, Never>?
    /// Bumped on each query reset so an in-flight task knows it's been superseded
    /// even if cancellation hasn't propagated yet.
    @State private var loadGeneration: Int = 0

    private static let pageSize = 30

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
                           defaultValue: "Search sessions"),
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
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

            ScrollView {
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
                            // Sentinel row: appearance triggers loadMore. Renders the
                            // "Loading more…" indicator while fetching.
                            loadingRow
                                .onAppear { loadMore() }
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 360)
        .background(
            EscapeKeyCatcher { onDismiss() }
        )
        .onAppear {
            resetAndLoad(query: "")
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: query) { newValue in
            resetAndLoad(query: newValue)
        }
        .onDisappear {
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

    /// Reset the page and load page 0.
    /// - Empty query: synchronous fast path. Show the cached top-N from
    ///   `section.entries` immediately so opening the popover never flashes a
    ///   loading spinner. The sentinel row's loadMore will then fetch any
    ///   additional pages from disk/SQL when the user scrolls past them.
    /// - Non-empty query: 200ms debounce then deep search via the store.
    private func resetAndLoad(query newValue: String) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = trimmed

        if trimmed.isEmpty {
            loaded = section.entries
            // Optimistic: assume there might be more on disk; loadMore will
            // discover the truth and flip hasMore off if a fetch returns nothing.
            hasMore = !section.entries.isEmpty
            isLoading = false
            return
        }

        loaded = []
        hasMore = true
        isLoading = true
        let scope = sectionSearchScope
        let store = self.store
        loadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled || generation != loadGeneration { return }
            let page = await store.searchSessions(
                query: trimmed, scope: scope,
                offset: 0, limit: Self.pageSize
            )
            if Task.isCancelled || generation != loadGeneration { return }
            loaded = page
            hasMore = page.count >= Self.pageSize
            isLoading = false
        }
    }

    /// Append the next page to `loaded`. Triggered by the sentinel row's onAppear.
    private func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let generation = loadGeneration
        let scope = sectionSearchScope
        let store = self.store
        let query = activeQuery
        let offset = loaded.count
        loadTask = Task { @MainActor in
            let page = await store.searchSessions(
                query: query, scope: scope,
                offset: offset, limit: Self.pageSize
            )
            if Task.isCancelled || generation != loadGeneration { return }
            loaded.append(contentsOf: page)
            hasMore = page.count >= Self.pageSize
            isLoading = false
        }
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
            Image(agent.assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            Image(entry.agent.assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 12, height: 12)
            Text(entry.displayTitle)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(Self.relativeFormatter.localizedString(for: entry.modified, relativeTo: Date()))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary.opacity(0.7))
                .fixedSize()
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
        DispatchQueue.main.async {
            let pb = NSPasteboard(name: .drag)
            let type = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
            pb.addTypes([type], owner: nil)
            pb.setData(data, forType: type)
        }
    }

    provider.suggestedName = entry.displayTitle
    return provider
}

// MARK: - NSPopover host

/// Hosts SectionPopoverView in a real NSPopover. SwiftUI's native `.popover()`
/// doesn't reliably let the embedded TextField become first responder in cmux's
/// focus-managed environment — the terminal keeps grabbing focus back.
private struct SectionPopoverHost: NSViewRepresentable {
    @Binding var isPresented: Bool
    let section: IndexSection
    let store: SessionIndexStore
    let onResume: ((SessionEntry) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

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
            store: store,
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

        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?
        private var currentSection: IndexSection?
        private var currentStore: SessionIndexStore?
        private var currentOnResume: ((SessionEntry) -> Void)?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func update(section: IndexSection, store: SessionIndexStore, onResume: ((SessionEntry) -> Void)?) {
            currentSection = section
            currentStore = store
            currentOnResume = onResume
            refreshContent()
        }

        private func refreshContent() {
            guard let section = currentSection, let store = currentStore else { return }
            let onResume = currentOnResume
            hostingController.rootView = AnyView(
                SectionPopoverView(section: section, store: store, onResume: onResume) { [weak self] in
                    self?.closeFromContent()
                }
            )
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

// MARK: - Escape key catcher

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
                if event.keyCode == 53 { // kVK_Escape
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
