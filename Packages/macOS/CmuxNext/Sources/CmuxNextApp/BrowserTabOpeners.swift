import CmuxNextDaemon

/// Where a page's new tab goes, in Chrome's order (cx-d0d.19,
/// plans/cmux-next/browser-parity.md Rank 1). This is Chromium's
/// `TabStripModel` opener model, rule for rule:
///
/// - Every link tab records its opener (`TabModel::opener`).
/// - A foreground tab goes right after the opener and first forgets every
///   relation (`ForgetAllOpeners`), then records its own.
/// - A background tab goes after the run of the opener's descendants
///   (children, grandchildren...) that directly follows the opener; the run
///   ends at the first tab outside the family, pinned tabs skipped
///   (`GetIndexOfLastWebContentsOpenedBy`). No run: right after the opener.
/// - A tab that leaves the pane hands its children its own opener
///   (`FixOpeners`).
/// - A user switch between tabs that are not opener and child or siblings
///   forgets every relation (`SetSelection` with a user gesture), and so
///   does a typed navigation (`TabNavigating`), except a new tab page at the
///   end of the strip.
///
/// The daemon commits the tab in the slot (`frontend-browser-insert-after-v1`);
/// this type only names it. Placements for one opener run one at a time:
/// the next slot depends on the tab the previous one made, and the caller's
/// `create` returns only once the store shows that tab
/// (`BrowserTabService.settled`).
final class BrowserTabOpeners {
    /// Each link tab's opener, by surface.
    private var openerOf: [SurfaceID: SurfaceID] = [:]
    /// The placement each opener's next one waits for.
    private var queue: [SurfaceID: Task<SurfaceID, any Error>] = [:]

    /// A page's new tab in `pane`: `create(nil)` (the end) without an
    /// opener; with one, in Chrome's slot, returning once the store shows
    /// the new tab.
    func open(_ opener: SurfaceID?, foreground: Bool, in pane: PaneModel, browserTabs: BrowserTabService,
              create: @escaping @MainActor (_ after: SurfaceID?) async throws -> SurfaceID) async throws -> SurfaceID {
        guard let opener else { return try await create(nil) }
        return try await place(opener: opener, foreground: foreground,
                               order: { [weak pane] in pane?.tabs.map(\.surface) ?? [] },
                               pinned: { [weak pane] in Set(pane?.tabs.filter(\.pinned).map(\.surface) ?? []) }) { after in
            let surface = try await create(after)
            await browserTabs.settled()
            return surface
        }
    }

    /// Creates the opener's new tab through `create(after)` in Chrome's slot
    /// and records the opener. `order` is the pane's tab order (surfaces) as
    /// the store shows it now; `pinned` its pinned tabs.
    func place(opener: SurfaceID, foreground: Bool, order: @escaping @MainActor () -> [SurfaceID],
               pinned: @escaping @MainActor () -> Set<SurfaceID> = { [] },
               create: @escaping @MainActor (_ after: SurfaceID) async throws -> SurfaceID) async throws -> SurfaceID {
        let previous = queue[opener]
        let placing = Task { [weak self] () async throws -> SurfaceID in
            // A failed earlier placement does not stop this one.
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            let after = foreground ? opener : self.slot(after: opener, in: order(), pinned: pinned())
            let child = try await create(after)
            if foreground { self.forgetAll() }
            if child != opener { self.openerOf[child] = opener }
            return child
        }
        queue[opener] = placing
        defer { if queue[opener] == placing { queue[opener] = nil } }
        return try await placing.value
    }

    /// The tab a background child goes after: the last tab of the run of
    /// the opener's descendants that directly follows it, else the opener.
    func slot(after opener: SurfaceID, in order: [SurfaceID], pinned: Set<SurfaceID> = []) -> SurfaceID {
        reconcile(with: order)
        guard let start = order.firstIndex(of: opener) else { return opener }
        var family: Set<SurfaceID> = [opener]
        var last: SurfaceID?
        for tab in order[order.index(after: start)...] {
            guard let parent = openerOf[tab], family.contains(parent) else {
                // New tabs go after pinned tabs: a pinned tab never ends the run.
                if pinned.contains(tab) { continue }
                break
            }
            family.insert(tab)
            last = tab
        }
        return last ?? opener
    }

    /// The user moved from tab `old` to tab `new` in a pane: every relation
    /// is forgotten unless one is the other's opener or both share one.
    func userActivated(from old: SurfaceID?, to new: SurfaceID?) {
        let oldOpener = old.flatMap { openerOf[$0] }
        let newOpener = new.flatMap { openerOf[$0] }
        let unrelated = newOpener != oldOpener
            && ((old == nil && newOpener == nil) || newOpener != old)
            && ((new == nil && oldOpener == nil) || oldOpener != new)
        if unrelated { forgetAll() }
    }

    /// A tab navigated by a typed URL: the user starts another task, so
    /// every relation is forgotten, except in a new tab page that is the
    /// last tab of its pane (a quick look-up keeps them for one navigation).
    func typedNavigation(onNewTabPageAtEnd: Bool) {
        if !onNewTabPageAtEnd { forgetAll() }
    }

    func forgetAll() {
        openerOf.removeAll()
    }

    /// Tabs the pane no longer shows (closed, moved away) leave the tree;
    /// their children take their opener (`FixOpeners`).
    private func reconcile(with order: [SurfaceID]) {
        let shown = Set(order)
        for gone in Set(openerOf.keys).union(openerOf.values) where !shown.contains(gone) {
            let inherited = openerOf.removeValue(forKey: gone)
            for (child, parent) in openerOf where parent == gone {
                openerOf[child] = inherited == child ? nil : inherited
            }
        }
    }
}
