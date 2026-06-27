// SectionPopoverSearchModel.swift
//
// The paged/snapshot search state machine for the Sessions sidebar "Show more"
// popover, extracted out of SectionPopoverView's view-local @State. This
// @Observable model owns the result/pagination bookkeeping (loaded rows,
// hasMore, loading flag, active query, errors, the directory snapshot, and the
// in-flight pagination task); the view keeps only the TextField `query` binding
// and the `@FocusState` for first-responder management.
//
// The view's `SessionSearchFn` / `DirectorySnapshotFn` collaborators and the
// `IndexSection` are passed in per call rather than cached, so each load/loadMore
// reads exactly the values the current render carries — byte-faithful to the
// original struct's fresh-read-per-render semantics.

import Foundation
import Observation

/// Drives the "Show more" popover's paged/snapshot search.
///
/// Owned by `SectionPopoverView` via `@State`, so it is recreated (reset to its
/// initial state) whenever the popover's SwiftUI identity changes — matching the
/// view-local `@State` reset the original implementation relied on.
@MainActor
@Observable
final class SectionPopoverSearchModel {
    /// Rows currently rendered in the popover. In snapshot mode this is a
    /// prefix of `fullSnapshot`; in typed-query mode it's the accumulated
    /// pages from the store.
    var loaded: [SessionEntry] = []
    var hasMore: Bool = true
    var isLoading: Bool = false
    var activeQuery: String = ""
    var errorMessages: [String] = []
    /// Full merged snapshot of the directory (empty-query directory scope
    /// only). When non-nil, `loadMore()` slices this array in memory
    /// instead of hitting the store.
    var fullSnapshot: [SessionEntry]?

    /// In-flight pagination task for the typed-query path. Reassigned by
    /// `loadMore()`; the previous task is cancelled implicitly. The initial /
    /// query-change load is owned by SwiftUI via `.task(id: query)` and
    /// doesn't use this slot. Not observation-tracked: it is never read from a
    /// view body, only managed internally.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let pageSize = 100

    /// Cancel any pagination task from the previous query lifecycle. Called by
    /// the view at the top of `.task(id: query)` before the focus handoff so a
    /// stale page can't land and append rows that don't match the new query.
    func cancelPagination() {
        loadTask?.cancel()
        loadTask = nil
    }

    /// Run the initial / query-change load for `query`. Invoked from the view's
    /// `.task(id: query)`, so cancellation (on view disappear or query change)
    /// propagates through the awaiting task: `Task.sleep` throws and the
    /// `Task.isCancelled` guards absorb the post-await window.
    func load(
        query: String,
        section: IndexSection,
        search: SessionSearchFn,
        loadSnapshot: DirectorySnapshotFn
    ) async {
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
            if case .directory(let path) = section.key.searchScope {
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

        let outcome = await search(trimmed, section.key.searchScope, 0, Self.pageSize)
        guard !Task.isCancelled else { return }
        applyOutcome(outcome, append: false)
    }

    /// Append the next page to `loaded`. Triggered by the sentinel row's
    /// onAppear. In snapshot mode (empty-query directory scope) this is a
    /// pure in-memory array slice with zero store calls. In typed-query mode
    /// it fires a paged search. Explicitly cancels any earlier load-more
    /// still in flight so a superseded page can't append stale rows after
    /// a query change.
    ///
    /// `section`/`search` are passed in fresh from the current render so the
    /// scope and search handle match the live view, never a cached value.
    func loadMore(section: IndexSection, search: @escaping SessionSearchFn) {
        guard !isLoading, hasMore else { return }

        if let snapshot = fullSnapshot {
            let next = min(loaded.count + Self.pageSize, snapshot.count)
            loaded = Array(snapshot.prefix(next))
            hasMore = next < snapshot.count
            return
        }

        isLoading = true
        let scope = section.key.searchScope
        let query = activeQuery
        let offset = loaded.count
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            let outcome = await search(query, scope, offset, Self.pageSize)
            guard !Task.isCancelled else { return }
            applyOutcome(outcome, append: true)
        }
    }

    /// Cancel the pagination task and clear the loading flag when the popover
    /// disappears. `.task(id: query)` auto-cancels its own load on disappear,
    /// but the separate `loadTask` slot is ours to manage.
    func handleDisappear() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    /// Merge a fetch result into the popover's display state. Both the
    /// initial-page and load-more paths converge here so the count/hasMore/
    /// error/loading bookkeeping lives in one place.
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
}
