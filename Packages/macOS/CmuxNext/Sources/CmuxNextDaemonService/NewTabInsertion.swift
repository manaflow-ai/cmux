public import CmuxNextActions
public import CmuxNextDaemon
public import CmuxNextWakeups

/// A person's new tab made in its slot by its creating commit: right after a tab of its pane (`tab-insert-after-v1`:
/// `after` on `new-tab` and `new-conversation-tab`, as `new-frontend-browser-tab` takes it).
///
/// Without it the daemon made every new tab at the end of its pane and the app moved it into its slot, one round trip
/// per tab: a held new-tab key left the daemon's order `a b 1 2 3 ...` for seconds, and the moves and closes in that
/// window went by the wrong order (Lawrence 2026-11-13). Each press shows its stand-in right after the tab the pane
/// showed at the press, which in a burst is the press before's stand-in: it has no daemon surface until its own
/// creation is answered. So a pane's creations are sent in press order, each once the one before it was answered
/// (one ``WorkLine`` per pane, shared by terminals, browsers and New Tab pages), and the tab to go after is read at send
/// time (``after()``). A tab the store cannot name sends nothing: the daemon appends, and `NewTabSlot`'s move puts the
/// tab in its slot, as for a daemon without the capability (which never gets an insertion).
///
/// The turn is taken at the press, in the key's turn (the stand-in still shows in it; only the send waits), and is
/// released by ``answered()`` once the creation's answer was applied, or when the insertion is let go (a creation that
/// was refused before it was sent, or whose work ended), or after ``answerLimit`` as a safety (``WorkTurn``).
///
/// ```swift
/// let insertion = NewTabInsertion(after: anchor, in: pane, daemon: controller.daemon, line: controller.creations)
/// // in the creation's work, before its request:
/// request.after = await insertion.after()
/// // once its answer is applied (ProvisionalTab.created) or it failed:
/// insertion.answered()
/// ```
@MainActor
public final class NewTabInsertion {
    /// How long the pane's next creation waits for this one's answer before it is sent anyway: a safety for an answer
    /// that never comes. That creation then names no tab it cannot know and is moved into its slot.
    public static let answerLimit: Duration = .seconds(10)

    private let anchor: TabModel
    /// The pane's tabs on the anchor's left at the press, nearest first: where the tab goes once the anchor left.
    private let earlier: [TabModel]
    private weak var pane: PaneModel?
    private let store: DaemonStore
    private let turn: WorkTurn<ActionWorkFailure?>

    /// Takes the new tab's place in its pane's send line now (call it at the press, before the creation's stand-in shows).
    /// Nil when the tab is made at the end and moved instead: a script's tab (no view change allowed) and a daemon
    /// without `tab-insert-after-v1`.
    /// - Parameters:
    ///   - anchor: the tab the new one goes right after, after its tab group: the tab the pane showed at the press, the
    ///     stand-in of the press before in a burst.
    ///   - pane: the pane the tab is made in.
    ///   - daemon: the pane's daemon; its store knows the daemon tab each answered stand-in became.
    ///   - line: the pane's creation line (`PaneController.creations`).
    public init?(after anchor: TabModel, in pane: PaneModel, daemon: DaemonService, line: WorkLine<ActionWorkFailure?>) {
        guard ActionRunScope.viewChangeAllowed(), daemon.supports(DaemonCapability.tabInsertAfter.rawValue) else { return nil }
        self.anchor = anchor
        earlier = pane.tabs.firstIndex { $0 === anchor || $0.id == anchor.id }.map { Array(pane.tabs[..<$0].reversed()) } ?? []
        self.pane = pane
        store = daemon.store
        turn = line.next(limit: Self.answerLimit, owner: "NewTabInsertion.answer", passing: nil)
    }

    /// The daemon surface to send as the creation's `after`, read once the pane's creation before this one was answered
    /// (or failed, or let its turn go). Call it at send time, in the creation's work.
    /// - Returns: the tab before the new tab's slot as the daemon knows it, nil to append.
    public func after() async -> SurfaceID? {
        _ = await turn.earlier?.value
        return resolved()
    }

    /// The creation was answered (its stand-in's daemon tab is known to the store) or failed: the pane's next creation
    /// is sent now. Idempotent; letting the insertion go does the same.
    public func answered() { turn.pass() }

    /// The tab before the slot among the pane's tabs: the anchor (by identity or id: the store may rebuild a record), or
    /// the daemon's tab the anchor's stand-in became; then the last tab of its group (the last pinned tab at least), as
    /// ``TabGroupWrites/slot(after:in:)`` places a new tab. Stand-ins of creations still under way (this one's own, a later
    /// press's) are no daemon tab and do not count. An anchor that left the pane (closed, refused) gives its place to the
    /// nearest tab that was on its left at the press and is still there, so the new tab keeps its slot (`a b N c` after the
    /// first of two new tabs closed). Nil when none is left or that tab is not the daemon's yet: the tab is appended and
    /// `NewTabSlot` moves it.
    private func resolved() -> SurfaceID? {
        guard let pane else { return nil }
        let creations = store.creations, closing = store.closingTabIDs // a tab whose close is on its way is no anchor: the daemon may close it first
        let others = pane.tabs.filter { !closing.contains($0.id) && !(ProvisionalTab.isProvisional($0.id) && creations.isUnderway(standIn: $0.id)) }
        func now(_ tab: TabModel) -> TabModel? { others.first { $0 === tab || $0.id == tab.id } ?? creations.replacement(ofStandIn: tab.id, in: pane) }
        guard let tab = now(anchor) ?? earlier.lazy.compactMap(now).first,
              let slot = TabGroupWrites.slot(after: tab, in: others), others.indices.contains(slot - 1) else { return nil }
        let before = others[slot - 1]
        return ProvisionalTab.isProvisional(before.id) ? creations.replacementSurface(ofStandIn: before.id) : before.surface
    }
}
