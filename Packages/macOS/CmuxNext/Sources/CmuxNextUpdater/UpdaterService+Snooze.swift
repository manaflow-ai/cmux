public import Foundation

/// UPDATE-CARD-CLOSE: the update cards' "Hide" button (the staged "Update Ready" card and the
/// found-update notice; one click hides this version until a newer one, Lawrence 2026-10-14) and
/// their right-click menu (``UpdateCardCloseOption``). Hiding never skips the update in Sparkle:
/// it still downloads and stages, a quit still installs it, and Check for Updates shows it.
extension UpdaterService {
    /// The right-click menu, in order: (action id, title).
    public static var updateCloseMenu: [(id: String, title: String)] {
        UpdateCardCloseOption.allCases.map { ($0.rawValue, $0.title) }
    }

    /// The Hide button's text. "Hide" says what one click does and fits beside "Update Ready" at
    /// the default sidebar width; "Skip This Version" would promise Sparkle's skip, which this is
    /// not (the update still installs on quit).
    public static var updateHideTitle: String { UpdaterStrings.text("updater.close.hide", "Hide") }
    /// The Hide button's tooltip and VoiceOver label: how long it hides.
    public static var updateCloseLabel: String { UpdateCardCloseOption.hideVersion.title }
    /// The Hide button's action id.
    public static var updateHideAction: String { UpdateCardCloseOption.hideVersion.rawValue }

    /// The update version a card shows now: the staged one, else the found one.
    var shownUpdateVersion: String? {
        switch flow.phase {
        case .ready(let version), .available(let version): version
        case .hidden, .checking, .downloading, .installing, .note: nil
        }
    }

    /// The Hide button or a right-click menu item: hide the shown update's version until a newer one, or every update card
    /// until the chosen time (persisted; a relaunch keeps it). With no update shown any more (it
    /// began installing while the menu was open), Hide Until a Newer Version does nothing: a
    /// recorded "" would hide every later update that names no version.
    public func closeUpdateCard(_ option: UpdateCardCloseOption) {
        if cancelledDownload != nil, flow.phase == .hidden {
            // A cancelled download's card: Sparkle holds nothing, so closing it only clears it.
            log.append("update card closed after a cancelled download: \(option.rawValue)")
            cancelledDownload = nil
            followCardExpiry()
            return
        }
        var snooze = updateSnooze
        if let length = option.remindLength {
            snooze.remindAfter = now().addingTimeInterval(length)
        } else {
            switch flow.phase {
            case .ready(let version), .available(let version):
                snooze.closedVersion = version ?? ""
            case .hidden, .checking, .downloading, .installing, .note:
                log.append("update card close ignored: no update shown")
                return
            }
        }
        log.append("update card closed: \(option.rawValue) version=\(shownUpdateVersion ?? "none")")
        storeUpdateSnooze(snooze)
        followCardExpiry()
        // A hidden found update no longer holds the fast check back (``TipUpdateCheck``).
        tipCheck.refresh(self)
    }

    /// The person asked to check or install, or an update the organization requires is shown
    /// again (`recheckRequiredUpdate()`, managed MinimumVersion): a closed or snoozed card shows again.
    public func clearUpdateSnooze() {
        storeUpdateSnooze(UpdateSnooze())
    }

    /// Drops a reminder that ended (the card comes back) and arms the one-shot deadline of a
    /// pending one: at launch, when cmux becomes active again, and after each change.
    public func refreshUpdateSnooze() {
        storeUpdateSnooze(updateSnooze.expired(at: now()))
    }

    func storeUpdateSnooze(_ snooze: UpdateSnooze) {
        if snooze != updateSnooze {
            updateSnooze = snooze
            snooze.save(to: defaults)
        }
        guard let end = snooze.remindAfter else { return snoozeTimer.cancel() }
        let seconds = max(0, end.timeIntervalSince(now()))
        snoozeTimer.schedule(after: .milliseconds(Int64((seconds * 1000).rounded(.up)))) { @MainActor [weak self] in
            self?.refreshUpdateSnooze()
        }
    }

    /// `debug.updater {action: "snooze", press?, at?}` (socket proofs): presses `press` (an
    /// ``UpdateCardCloseOption`` id, or `clear`) like the button or the menu does, or else re-reads the
    /// reminder as at launch at `at` (epoch seconds, default now: a reminder that ended there
    /// clears). Returns the closed version, the reminder's end, and whether each card shows.
    public func debugSnooze(press: String?, at epoch: Double?) -> [String: String] {
        if press == "clear" {
            clearUpdateSnooze()
        } else if let press {
            guard let option = UpdateCardCloseOption(rawValue: press) else { return ["error": "unknown option \(press)"] }
            closeUpdateCard(option)
        } else if let epoch {
            storeUpdateSnooze(updateSnooze.expired(at: Date(timeIntervalSince1970: epoch)))
        } else {
            refreshUpdateSnooze()
        }
        var state = ["readyCard": String(readyCard != nil), "noticeCard": card?.kind ?? "none"]
        state["closedVersion"] = updateSnooze.closedVersion
        state["remindAfter"] = updateSnooze.remindAfter.map { ISO8601DateFormatter().string(from: $0) }
        return state
    }
}
