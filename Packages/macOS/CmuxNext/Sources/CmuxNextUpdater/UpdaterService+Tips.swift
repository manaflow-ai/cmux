import AppKit
import CmuxNextSettings
public import Foundation

/// The "Did you know" card (BOTTOM-LEFT-CARDS K1): a tip for a feature the
/// user has not used, at most one every 14 days across every tip in the app
/// (``TipChooser``, `FeatureTipBudget`), picked only at launch and when cmux
/// becomes active again (never while the user works in it), dismissable per
/// tip, muted for a day or a week (``TipMenuOption``; the end is read only
/// here, when a tip would show), off with `sidebar.cards.tips`. Usage flags
/// stay on this Mac.
extension UpdaterService {
    /// Picks today's tip (``TipChooser``) and saves the choice; none while
    /// tips are off or a timed mute holds at `date` (default now).
    public func refreshTip(at date: Date? = nil) {
        let date = date ?? now()
        guard tipsEnabled == true, !tipsMuted(at: date) else {
            if tip != nil { tip = nil }
            return
        }
        let (next, state) = TipChooser.choose(TipCatalog.all, state: tipState, today: TipState.day(date), showing: tip?.id,
                                              budgetOpen: tipBudget.isOpen(at: date))
        storeTipState(state)
        if tip != next { tip = next }
    }

    /// A return to cmux re-picks the tip (a new day's tip, or the end of a
    /// timed mute) and re-reads the update card's reminder (a Mac that slept
    /// past it); the App calls this once at launch.
    public func refreshTipOnActivation() {
        activationObservation?.cancel()
        activationObservation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.refreshTip()
                self?.refreshUpdateSnooze()
            }
        }
    }

    /// The user ran `action` (palette, menu, shortcut, click): its tip is
    /// used. Only the user's own runs count (the App filters the origin).
    public func markTipActionUsed(_ action: String) {
        guard !tipState.usedActions.contains(action), TipCatalog.all.contains(where: { $0.action == action }) else { return }
        var state = tipState
        state.usedActions.insert(action)
        storeTipState(state)
        if tip?.action == action { tip = nil }
    }

    /// "Try It": runs the tip's action as the user's; the card closes for today.
    public func tryTip(_ id: String) {
        guard let tip = TipCatalog.all.first(where: { $0.id == id }) else { return }
        markTipActionUsed(tip.action)
        runTipAction?(tip.action)
    }

    /// The card's x: this tip never shows again; no other tip today.
    public func dismissTip(_ id: String) {
        var state = tipState
        state.dismissed.insert(id)
        storeTipState(state)
        if tip?.id == id { tip = nil }
    }

    /// DEV/NIGHTLY screenshots (`debug.updater {action: "tip", id?}`): shows
    /// tip `id` (the first by default) today, ignoring usage; nil clears.
    public func debugShowTip(_ id: String?) {
        guard let id else {
            tip = nil
            return
        }
        tip = TipCatalog.all.first { $0.id == id } ?? TipCatalog.all.first
    }

    /// The one record of when a tip last showed, shared with the agent chat's feature tips.
    var tipBudget: FeatureTipBudget { FeatureTipBudget(defaults: defaults) }

    func storeTipState(_ state: TipState) {
        guard state != tipState else { return }
        tipState = state
        state.save(to: defaults)
    }
}

extension UpdaterService {
    /// The card's small heading ("Did you know?").
    public static var tipEyebrow: String { UpdaterStrings.tipEyebrow }
}
