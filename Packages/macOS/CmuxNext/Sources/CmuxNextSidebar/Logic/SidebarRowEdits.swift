import CmuxNextCompat
import CmuxNextDesign

/// A window's pending row edits and folds, held across live projections until their owner has them.
/// The app supplies redraw and confirmed-fold callbacks; this state has no daemon or window dependency.
@MainActor
public final class SidebarRowEdits {
    private let model: SidebarModel
    private let redraw: @MainActor () -> Void
    private let confirmedFold: @MainActor (GroupID, Bool) -> Void
    private var pending = SidebarPendingEdits()
    private var folds: [GroupID: Fold] = [:]
    private var foldSerial = 0
    private var foldFollow: Task<Void, Never>?

    private struct Fold {
        var collapsed: Bool
        var serial: Int
        var untilShown = false
    }

    /// Creates state for one sidebar, with callbacks that redraw its rows and update its live fold cache.
    public init(model: SidebarModel, redraw: @escaping @MainActor () -> Void,
                confirmedFold: @escaping @MainActor (GroupID, Bool) -> Void) {
        self.model = model
        self.redraw = redraw
        self.confirmedFold = confirmedFold
    }

    /// Applies pending edits to the owner's rows, before pending creates are inserted.
    public func applying(to live: [SidebarSection]) -> [SidebarSection] { pending.apply(to: live) }

    /// Holds pending folds over the composed rows. A document fold leaves once the live rows show it.
    public func applyFolds(to sections: inout [SidebarSection]) {
        for (group, fold) in folds {
            guard let (s, n) = SidebarEdits.locateGroup(group, in: sections), case var .group(shown) = sections[s].nodes[n] else { continue }
            guard shown.isCollapsed != fold.collapsed else {
                if fold.untilShown { folds[group] = nil }
                continue
            }
            shown.isCollapsed = fold.collapsed
            sections[s].nodes[n] = .group(shown)
        }
    }

    /// Shows a fold now and returns its settlement. A later click's fold is never settled by this one.
    public func fold(_ group: GroupID, collapsed: Bool) -> @MainActor () -> Void {
        foldSerial += 1
        let serial = foldSerial
        folds[group] = Fold(collapsed: collapsed, serial: serial)
        model.setGroupCollapsed(group, collapsed)
        return { [weak self] in
            guard let self, folds[group]?.serial == serial else { return }
            folds[group] = nil
        }
    }

    /// Shows a document fold until its echo reaches the live rows, or a refusal drops it.
    public func foldShown(_ group: GroupID, collapsed: Bool) {
        foldSerial += 1
        folds[group] = Fold(collapsed: collapsed, serial: foldSerial, untilShown: true)
        model.setGroupCollapsed(group, collapsed)
    }

    /// Drops a refused document fold and redraws the owner's rows.
    public func dropFold(_ group: GroupID) {
        guard folds.removeValue(forKey: group) != nil else { return }
        redraw()
    }

    /// Follows fold-only document batches without rebuilding all rows.
    public func followFolds(of store: SidebarDocStore) {
        foldFollow?.cancel()
        // task-owner: this window's row edits; ends when they or the store go away, replaced by a second call
        foldFollow = Task { [weak self, weak store] in
            for await _ in ObservationStream({ store?.foldRevision }) {
                guard let self, let store else { return }
                for (id, collapsed) in store.lastFolds {
                    let group = GroupID(id)
                    if let held = folds[group] {
                        // Earlier echoes cannot replace a newer click's look.
                        if held.untilShown, held.collapsed == collapsed {
                            folds[group] = nil
                            confirmedFold(group, collapsed)
                        }
                        continue
                    }
                    confirmedFold(group, collapsed)
                    model.setGroupCollapsed(group, collapsed)
                }
            }
        }
    }

    /// Shows an intent until its commands settle.
    public func add(_ intent: SidebarIntent) -> SidebarPendingEdits.Token {
        let edit = pending.add(intent)
        redraw()
        return edit
    }

    /// Releases an edit and redraws the owner's current state.
    public func settle(_ edit: SidebarPendingEdits.Token?) {
        guard let edit else { return }
        pending.settle(edit)
        redraw()
    }

    /// Settlement callbacks for a command: failure releases the edit before reporting; success waits for its owner.
    public func outcome<Failure>(_ edit: SidebarPendingEdits.Token?, failed onFailure: @escaping @MainActor (Failure) -> Void)
        -> (failed: @MainActor (Failure) -> Void, applied: (@MainActor () -> Void)?) {
        let failed: @MainActor (Failure) -> Void = { [weak self] failure in
            self?.settle(edit)
            onFailure(failure)
        }
        guard let edit else { return (failed, nil) }
        return (failed, { [weak self] in self?.settle(edit) })
    }
}
