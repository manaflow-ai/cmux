public import AppKit
public import CmuxSessionIndex
public import SwiftUI

/// The "Show more" search popover body for one session-index section.
///
/// A pure presentation view: it owns its search/scroll view-local state, paginates
/// through the injected ``SessionSearchFn`` (typed query) or an in-memory slice of the
/// injected ``DirectorySnapshotFn`` (empty-query directory scope), and renders each
/// result as a ``PopoverRow``. It never holds a reference to the session-index store;
/// the host owns the store and passes only closures, so no view below the lazy-list
/// boundary can subscribe to broad store updates.
///
/// App-resolved seams (the popover reaches no app-side state directly):
/// - `displayTitle` resolves a row's localized title (`SessionEntry.displayTitle` binds
///   `String(localized:)` against the host app bundle).
/// - `agentIcon` resolves an agent's icon names (the asset-catalog names live in the app).
/// - `dragItemProvider` builds the `NSItemProvider` the host registers against its session
///   drag registry.
/// - `menuContent` builds the right-click menu the host shares with the full session row;
///   it reaches `NSWorkspace`/`NSPasteboard` and app-bundle localization, so it stays
///   app-side and is injected as a `@ViewBuilder` per entry.
public struct SectionPopoverView<MenuContent: View>: View {
    private let section: IndexSection
    /// Closure-typed search handle. The popover never holds a reference to the
    /// session-index store; the host is the only owner.
    private let search: SessionSearchFn
    /// Closure that returns the full merged snapshot for a directory. Used on the
    /// empty-query directory-scope scroll path so pagination is an in-memory array
    /// slice, not repeated store round-trips.
    private let loadSnapshot: DirectorySnapshotFn
    private let onResume: ((SessionEntry) -> Void)?
    private let onDismiss: () -> Void
    /// App-resolved chrome strings (search placeholder, empty/end-of-list/loading text).
    private let strings: SectionPopoverStrings
    /// Resolves a row's app-localized display title.
    private let displayTitle: (SessionEntry) -> String
    /// Resolves the app-side icon names for an agent (section header + rows).
    private let agentIcon: (SessionAgent) -> AgentIconPresentation
    /// Builds the drag payload the host registers for a given row.
    private let dragItemProvider: @MainActor (SessionEntry) -> NSItemProvider
    /// Builds the shared right-click menu for a given row.
    @ViewBuilder private let menuContent: (SessionEntry) -> MenuContent

    /// Creates a "Show more" popover body.
    /// - Parameters:
    ///   - section: The section whose sessions this popover searches.
    ///   - search: Paginated search handle (typed-query path).
    ///   - loadSnapshot: Full merged directory snapshot fetch (empty-query directory path).
    ///   - onResume: Invoked to resume a session in a new tab, or `nil`.
    ///   - strings: App-resolved localized chrome strings.
    ///   - displayTitle: Resolves a row's app-localized display title.
    ///   - agentIcon: Resolves an agent's app-side icon names.
    ///   - dragItemProvider: Builds the drag payload the host registers for a row.
    ///   - menuContent: Builds the shared right-click menu for a row.
    ///   - onDismiss: Closes the popover.
    public init(
        section: IndexSection,
        search: @escaping SessionSearchFn,
        loadSnapshot: @escaping DirectorySnapshotFn,
        onResume: ((SessionEntry) -> Void)?,
        strings: SectionPopoverStrings,
        displayTitle: @escaping (SessionEntry) -> String,
        agentIcon: @escaping (SessionAgent) -> AgentIconPresentation,
        dragItemProvider: @escaping @MainActor (SessionEntry) -> NSItemProvider,
        @ViewBuilder menuContent: @escaping (SessionEntry) -> MenuContent,
        onDismiss: @escaping () -> Void
    ) {
        self.section = section
        self.search = search
        self.loadSnapshot = loadSnapshot
        self.onResume = onResume
        self.strings = strings
        self.displayTitle = displayTitle
        self.agentIcon = agentIcon
        self.dragItemProvider = dragItemProvider
        self.menuContent = menuContent
        self.onDismiss = onDismiss
    }

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

    private static var pageSize: Int { 100 }

    public var body: some View {
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
                    strings.searchPlaceholder,
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
                        Text(strings.noMatches)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(loaded) { entry in
                            let presentation = agentIcon(entry.agent)
                            PopoverRow(
                                entry: entry,
                                displayTitle: displayTitle(entry),
                                agentAssetName: presentation.assetName,
                                agentSystemImageName: presentation.systemImageName,
                                onActivate: {
                                    onResume?(entry)
                                    onDismiss()
                                },
                                dragItemProvider: { dragItemProvider(entry) },
                                menuContent: {
                                    menuContent(entry)
                                }
                            )
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
                            Text(strings.endOfList)
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
            Text(strings.loading)
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
    private func applyOutcome(_ outcome: SearchOutcome, append: Bool) {
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

    private var sectionSearchScope: SearchScope {
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
            let presentation = agentIcon(agent)
            AgentIconImage(
                assetName: presentation.assetName,
                systemImageName: presentation.systemImageName,
                size: 14
            )
        case .folder:
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}
