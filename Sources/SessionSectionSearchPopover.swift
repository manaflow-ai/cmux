// SessionSectionSearchPopover.swift
//
// The Sessions sidebar "Show more" search popover subsystem, split out of
// SessionIndexView.swift. SectionPopoverView drives the paged/snapshot search
// state machine; PopoverRow renders one result row; RelativeTimestampSchedule
// is its self-rescheduling relative-time TimelineSchedule; SectionPopoverHost
// hosts the SwiftUI body inside a real NSPopover so the search field can take
// first responder in cmux's focus-managed environment.
//
// These types stay in the app target alongside their app-side seam values
// (SessionIndexStore.SearchScope/SearchOutcome, IndexSection, SectionKey,
// SessionAgent, SessionEntry, DirectorySnapshot); this is a file split, not a
// package move.

import AppKit
import CmuxAppKitSupportUI
import SwiftUI

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
            entry.dragItemProvider()
        }
        .help(entry.cwdLabel ?? entry.displayTitle)
        .contextMenu {
            SessionRowMenuItems(entry: entry, onResume: { _ in onActivate() })
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

