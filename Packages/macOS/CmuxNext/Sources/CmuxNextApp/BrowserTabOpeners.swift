import CmuxNextDaemon

/// Where a page's new tab goes, in Chrome's order (cx-d0d.19,
/// plans/cmux-next/browser-parity.md Rank 1): a background tab (Cmd-click,
/// middle click, Open Link in New Tab) goes right after the opener's last
/// child, so three Cmd-clicks show right of the opener in click order; a
/// foreground tab goes right after the opener and ends every earlier
/// opener relation, as Chrome's `ForgetAllOpeners`. The daemon commits the
/// tab in that slot (`frontend-browser-insert-after-v1`); this type only
/// names the slot.
///
/// Placements for one opener run one at a time: the next slot depends on
/// the tab the previous one made, and the caller's `create` returns only
/// once the store shows that tab (`BrowserTabService.settled`).
final class BrowserTabOpeners {
    /// Each opener's children, in creation order.
    private var children: [SurfaceID: [SurfaceID]] = [:]
    /// The placement each opener's next one waits for.
    private var queue: [SurfaceID: Task<SurfaceID, any Error>] = [:]

    /// A page's new tab in `pane`: `create(nil)` (the end) without an
    /// opener; with one, in Chrome's slot, returning once the store shows
    /// the new tab.
    func open(_ opener: SurfaceID?, foreground: Bool, in pane: PaneModel, browserTabs: BrowserTabService,
              create: @escaping @MainActor (_ after: SurfaceID?) async throws -> SurfaceID) async throws -> SurfaceID {
        guard let opener else { return try await create(nil) }
        return try await place(opener: opener, foreground: foreground, order: { [weak pane] in pane?.tabs.map(\.surface) ?? [] }) { after in
            let surface = try await create(after)
            await browserTabs.settled()
            return surface
        }
    }

    /// Creates the opener's new tab through `create(after)` in Chrome's slot
    /// and records it as the opener's child. `order` is the pane's tab
    /// order (surfaces) as the store shows it now.
    func place(opener: SurfaceID, foreground: Bool, order: @escaping @MainActor () -> [SurfaceID],
               create: @escaping @MainActor (_ after: SurfaceID) async throws -> SurfaceID) async throws -> SurfaceID {
        let previous = queue[opener]
        let placing = Task { [weak self] () async throws -> SurfaceID in
            // A failed earlier placement does not stop this one.
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            let after = foreground ? opener : self.slot(after: opener, in: order())
            let child = try await create(after)
            if foreground { self.children.removeAll() }
            self.children[opener, default: []].append(child)
            return child
        }
        queue[opener] = placing
        defer { if queue[opener] == placing { queue[opener] = nil } }
        return try await placing.value
    }

    /// The tab a background child goes after: the opener's child furthest
    /// right of the opener, else the opener. A child the pane no longer
    /// shows (closed, moved away) is no longer the opener's child.
    func slot(after opener: SurfaceID, in order: [SurfaceID]) -> SurfaceID {
        let shown = (children[opener] ?? []).filter(order.contains)
        children[opener] = shown.isEmpty ? nil : shown
        guard let start = order.firstIndex(of: opener) else { return opener }
        let right = shown.compactMap { order.firstIndex(of: $0) }.filter { $0 > start }
        return right.max().map { order[$0] } ?? opener
    }
}
