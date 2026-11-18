public import CmuxNextDaemon

/// Private tabs anywhere (Leo, 2026-11-18): which tabs read private before their record's `extra.private`
/// (`private-tabs-v1`) arrives. The tabs this process opened private in a normal pane, until the incognito
/// session ends; and the panes with a private tab on its way (no reply yet), with the tabs they held when it
/// began: a tab that appears there meanwhile reads private, so no page of the new tab ever starts in a normal
/// profile.
public struct PrivateTabLedger {
    /// A pane on one machine (handles are per daemon).
    public struct PaneKey: Hashable, Sendable {
        let machine: String
        let pane: PaneID
    }

    private struct SurfaceKey: Hashable {
        let machine: String
        let surface: SurfaceID
    }

    private var surfaces: Set<SurfaceKey> = []
    private var openings: [PaneKey: (count: Int, known: Set<String>)] = [:]

    public init() {}

    /// True while a private tab's create waits for its reply.
    public var isOpening: Bool { !openings.isEmpty }

    /// True for a private browser tab: its record says `extra.private`, this process opened it private, or it
    /// appeared in a pane while a private tab was on its way there. `daemon` (its machine and store) is asked only
    /// when the ledger holds something.
    public func isPrivate(_ tab: TabModel, daemon: () -> (machine: String, store: DaemonStore)) -> Bool {
        if tab.isPrivate { return true }
        guard tab.kind == .browser, !surfaces.isEmpty || !openings.isEmpty else { return false }
        let (machine, store) = daemon()
        if surfaces.contains(SurfaceKey(machine: machine, surface: tab.surface)) { return true }
        guard !openings.isEmpty, let pane = store.pane(holding: tab),
              let opening = openings[PaneKey(machine: machine, pane: pane.handle)] else { return false }
        return !opening.known.contains(tab.id)
    }

    /// A private tab's create in `pane` of `store` begins: the tabs the pane holds now are not it.
    public mutating func begin(in pane: PaneID, of store: DaemonStore, machine: String) -> PaneKey {
        let slot = PaneKey(machine: machine, pane: pane)
        let held = Set(store.pane(pane)?.tabs.map(\.id) ?? [])
        let current = openings[slot]
        openings[slot] = (count: (current?.count ?? 0) + 1, known: current?.known ?? held)
        return slot
    }

    /// The create that `begin` returned `slot` for has its reply (or failed).
    public mutating func end(_ slot: PaneKey) {
        guard let current = openings[slot] else { return }
        openings[slot] = current.count > 1 ? (count: current.count - 1, known: current.known) : nil
    }

    /// The private tab on `surface` of `machine` was opened here.
    public mutating func opened(_ surface: SurfaceID, machine: String) {
        surfaces.insert(SurfaceKey(machine: machine, surface: surface))
    }

    /// The incognito session ended: no tab opened here is private any more.
    public mutating func forget() { surfaces.removeAll() }
}
