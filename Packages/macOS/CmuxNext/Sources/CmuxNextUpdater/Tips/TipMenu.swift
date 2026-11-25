public import Foundation
import CmuxNextSettings

/// A setting the updater writes through the App (`UpdaterService.writeSetting`):
/// the App owns the settings file and maps each case to its path.
nonisolated public enum UpdaterSetting: Sendable {
    /// `updates.downloadAutomatically` (the update card's checkbox).
    case automaticUpdates
    /// `sidebar.cards.tips` ("Never Show Tips" writes false).
    case tips
}

/// What the tip card's x and right-click menu offer (Lawrence 2026-10-13):
/// hide this tip only, mute every tip for a day or a week, or turn tips
/// off. "Never Show Tips" writes `sidebar.cards.tips` = false (Settings,
/// the schema and MDM show it; Settings > Show Tips turns tips back on).
nonisolated public enum TipMenuOption: String, CaseIterable, Sendable {
    case hide = "tip-hide"
    case muteDay = "tip-mute-day"
    case muteWeek = "tip-mute-week"
    case never = "tip-never"

    public var title: String {
        switch self {
        case .hide: UpdaterStrings.tipDismiss
        case .muteDay: UpdaterStrings.text("updater.tip.muteDay", "Mute Tips for 1 Day")
        case .muteWeek: UpdaterStrings.text("updater.tip.muteWeek", "Mute Tips for 1 Week")
        case .never: UpdaterStrings.text("updater.tip.never", "Never Show Tips")
        }
    }

    /// How long a timed mute lasts; nil for the others.
    var muteLength: TimeInterval? {
        switch self {
        case .muteDay: 24 * 60 * 60
        case .muteWeek: 7 * 24 * 60 * 60
        case .hide, .never: nil
        }
    }
}

extension UpdaterService {
    /// The x's menu, in order: (action id, title).
    public static var tipMenu: [(id: String, title: String)] { TipMenuOption.allCases.map { ($0.rawValue, $0.title) } }
    /// The x's tooltip and VoiceOver label (it opens ``tipMenu``).
    public static var tipMenuLabel: String { UpdaterStrings.text("updater.tip.options", "Hide or Mute Tips") }

    /// The action the tip card sends once its tip is on screen (``markTipSeen(_:)``).
    public static let tipShownAction = "shown"
    /// The action the tip card sends when a tip it showed leaves the card
    /// (another card took the slot): a seen tip does not come back.
    public static let tipHiddenAction = "hidden"

    /// A tip card button or menu item: "Try It" (`try`), a ``TipMenuOption``,
    /// or ``tipShownAction``.
    public func tipCardAction(_ id: String, _ action: String) {
        if action == "try" { return tryTip(id) }
        if action == Self.tipShownAction { return markTipSeen(id) }
        if action == Self.tipHiddenAction {
            if tip?.id == id, tipState.seen.contains(id) { tip = nil }
            return
        }
        guard let option = TipMenuOption(rawValue: action) else { return }
        if let length = option.muteLength {
            muteTips(until: now().addingTimeInterval(length))
        } else if option == .never {
            // The setting's echo sets tipsEnabled (one writer: the settings file).
            tip = nil
            writeSetting?(.tips, false)
        } else {
            dismissTip(id)
        }
    }

    /// No tip until `date`; the next pick after it (launch, return to cmux)
    /// shows one again. Today's choice is kept.
    func muteTips(until date: Date) {
        var state = tipState
        state.mutedUntil = date
        storeTipState(state)
        tip = nil
    }

    /// Whether a timed mute holds at `date`; an ended one is cleared.
    func tipsMuted(at date: Date) -> Bool {
        guard let until = tipState.mutedUntil else { return false }
        if date < until { return true }
        var state = tipState
        state.mutedUntil = nil
        storeTipState(state)
        return false
    }

    /// The person saw tip `id` on the card: it is never picked again (it
    /// stays on the card for now), and no other tip in the app shows for
    /// `FeatureTipBudget.minimumDaysBetweenTips` days.
    func markTipSeen(_ id: String) {
        guard !tipState.seen.contains(id), TipCatalog.all.contains(where: { $0.id == id }) else { return }
        var state = tipState
        state.seen.insert(id)
        storeTipState(state)
        tipBudget.spend(at: now())
    }

    /// `sidebar.cards.tips` turned on again: a timed mute ends too.
    func tipsTurnedOn() {
        guard tipState.mutedUntil != nil else { return }
        var state = tipState
        state.mutedUntil = nil
        storeTipState(state)
    }

    /// `debug.updater {action: "tips", press?, at?}` (socket proofs): presses
    /// `press` on the shown tip (`try` or a ``TipMenuOption`` id) like its
    /// card does, or else picks as at launch at `at` (epoch seconds, default
    /// now); returns the tip shown, `sidebar.cards.tips`, the mute's end and
    /// the seen tips (`error` when `press` finds no tip shown). `press:
    /// "reset"` forgets everything the tips remember, the shared last-tip
    /// date included (a fresh install).
    public func debugTips(press: String?, at epoch: Double?) -> [String: String] {
        if press == "reset" {
            tip = nil
            tipBudget.reset()
            storeTipState(TipState(installSettled: true))
        } else if let press {
            guard let id = tip?.id else { return ["error": "no tip shown to press \(press) on"] }
            tipCardAction(id, press)
        } else {
            refreshTip(at: epoch.map(Date.init(timeIntervalSince1970:)))
        }
        var state = ["enabled": tipsEnabled.map(String.init) ?? "unknown"]
        state["tip"] = tip?.id
        state["mutedUntil"] = tipState.mutedUntil.map { ISO8601DateFormatter().string(from: $0) }
        state["seen"] = tipState.seen.sorted().joined(separator: ",")
        return state
    }
}
