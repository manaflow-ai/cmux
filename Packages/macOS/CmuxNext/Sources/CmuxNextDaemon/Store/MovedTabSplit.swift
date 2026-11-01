import Foundation

/// A pending split whose pane is made by moving a tab into it (Split Browser: no daemon request makes an app-rendered
/// browser in a new split, so the tab is made in the source pane and moved). The daemon's pane gets its own public id,
/// not the stand-in's, so the split's overlay finds it as the pane the moved tab landed in: the move's apply shows that
/// pane in the stand-in's place, and the stand-in never shows beside it (``ProvisionalSplit/daemonPane(_:in:)``).
struct MovedTabSplit {
    /// The moved tab's surface.
    let surface: SurfaceID
    /// The pane it is made in and moves out of (the split's target).
    let source: PaneID
    /// The stand-in pane's handle.
    let standIn: PaneID
    /// Runs once, right after the apply that lands the tab, before any view observes it (``takeLanded(in:)``).
    var landed: (@MainActor (SurfaceID) -> Void)?

    /// The pane the moved tab of `provisional`'s split landed in: any pane holding it but its source and the stand-in.
    @MainActor static func landedPane(of provisional: ProvisionalPane, in store: DaemonStore) -> PaneModel? {
        landedPane(ofStandIn: provisional.paneID, in: store)
    }

    /// The same by the stand-in's public pane id (a create aimed at the stand-in, ``ProvisionalSplit/daemonPane(of:showing:in:)``).
    @MainActor static func landedPane(ofStandIn paneID: String, in store: DaemonStore) -> PaneModel? {
        guard !store.movedTabSplits.isEmpty, let moved = store.movedTabSplits[paneID] else { return nil }
        return moved.landedPane(in: store)
    }

    /// Keeps the entries a split in the log names (a cancelled one too: its close hides the landed pane), and those a
    /// create aimed at the stand-in still resolves through (``DaemonStore/standInTargets``, ``DaemonStore/standInWaits``).
    @MainActor static func prune(in store: DaemonStore) {
        guard !store.movedTabSplits.isEmpty else { return }
        var kept = Set(store.intentLog.entries.compactMap { entry -> String? in
            if case .splitPane(_, _, _, let provisional) = entry.kind { return provisional.paneID }
            return nil
        })
        for origin in Array(store.standInTargets.values) + store.standInWaits.compactMap(\.origin) {
            if case .pane(let paneID) = origin { kept.insert(paneID) }
        }
        store.movedTabSplits = store.movedTabSplits.filter { kept.contains($0.key) }
    }

    @MainActor private func landedPane(in store: DaemonStore) -> PaneModel? {
        guard let pane = store.index.tabsBySurface[surface].flatMap(store.index.pane(holding:)),
              pane.handle != source, pane.handle != standIn else { return nil }
        return pane
    }

    /// Takes each split's `landed` once its tab is in another pane, in the apply that put it there (the confirmed
    /// records; the move's echo may settle the split in that same apply, so this runs before the settled entries go).
    /// The store runs them once that apply is over and the visible state is back, before any view observes it, so
    /// what the app made for the stand-in (its page) moves to the daemon's tab before any view shows that pane.
    @MainActor static func takeLanded(in store: DaemonStore) -> [(@MainActor (SurfaceID) -> Void, SurfaceID)] {
        guard !store.movedTabSplits.isEmpty else { return [] }
        var taken: [(@MainActor (SurfaceID) -> Void, SurfaceID)] = []
        for (paneID, moved) in store.movedTabSplits {
            guard let landed = moved.landed, moved.landedPane(in: store) != nil else { continue }
            store.movedTabSplits[paneID]?.landed = nil
            // A split the person closed first hands nothing over: its pane stays hidden and closes.
            let cancelled = store.intentLog.entries.contains { entry in
                guard entry.closeWhenCreated, case .splitPane(_, _, _, let provisional) = entry.kind else { return false }
                return provisional.paneID == paneID
            }
            if !cancelled { taken.append((landed, moved.surface)) }
        }
        return taken
    }
}

extension DaemonStore {
    /// The pending split showing `provisional` gets its pane by a move: tab `surface`, made in `source`, moves into it.
    /// `landed` runs once right after the apply that lands it (``MovedTabSplit/takeLanded(in:)``). Call once the tab exists
    /// and before the move goes out. Forgotten when the split leaves the log.
    public func adoptMovedTab(_ surface: SurfaceID, for provisional: ProvisionalPane, from source: PaneID,
                              landed: @escaping @MainActor (SurfaceID) -> Void) {
        movedTabSplits[provisional.paneID] = MovedTabSplit(surface: surface, source: source, standIn: provisional.handle, landed: landed)
    }
}
