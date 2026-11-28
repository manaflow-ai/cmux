import CmuxNextActions
import CmuxNextUpdater
import Foundation

/// Update actions (menu, palette, shortcut, CLI `settings check-for-updates`, `app relaunch` etc.) over the one
/// `UpdaterService`. Checks always run: release builds use Sparkle, DEV builds probe the feed read-only. Install
/// and channel switch are disabled, with the reason, where they cannot run.
enum UpdateHandlers {
    static func bind(into registry: ActionRegistry, updater: UpdaterService, openWhatsNew: @escaping @MainActor () -> Bool = { false },
                     whatsNewUnavailable: @escaping @MainActor () -> String? = { nil },
                     stateDirectories: @escaping @MainActor () -> [URL?] = { [nil] },
                     openLink: @escaping @MainActor (URL) -> Void = { _ in }) {
        // The What's New top page (WHATS-NEW-AFTER-UPDATE): palette, Help menu, CLI.
        registry.bind("updates.whatsNew", unavailable: whatsNewUnavailable, invoke: { _ in _ = openWhatsNew() })
        // announcements.enabled through the one setting path (palette.toggleSetting).
        for (id, on) in [("announcements.show", true), ("announcements.hide", false)] {
            registry.bind(ActionID(rawValue: id), run: { [weak registry] invocation in
                _ = registry?.perform("palette.toggleSetting", invocation: ActionInvocation(
                    arguments: ["setting": .string("announcements.enabled"), "on": .bool(on)], origin: invocation.origin))
            })
        }
        // A CLI run answers the feed's result (current and newest build) or the check's failure
        // (``UpdaterService/checkAnswer()``); a menu or palette run reads it on the notice card.
        registry.bind("palette.checkForUpdates", run: { [weak registry] _ in
            updater.checkForUpdates()
            guard let registry, registry.isCapturingWork else { return }
            registry.track(result: result(updater.checkAnswer()))
        })
        UpdateStatusAction.bind(into: registry, updater: updater)
        for id: ActionID in ["palette.applyUpdateIfAvailable", "palette.attemptUpdate"] {
            registry.bind(id, unavailable: { updater.installUnavailableReason }, invoke: { [weak registry] _ in
                // Taken before the request: only a phase the request reached answers a CLI run.
                let baseline = updater.settledFlowMoves()
                do { try updater.installAvailableUpdate() } catch { registry?.refuse(String(describing: error)); return }
                // A CLI run answers once the update installs, or with why nothing installs (``UpdaterService/installAnswer(after:limit:)``).
                guard let registry, registry.isCapturingWork else { return }
                registry.track(result: result(updater.installAnswer(after: baseline)))
            })
        }
        registry.bind("relaunchKeepSessions", run: { [weak registry] in registry?.track(result: result(updater.relaunchAnswer(ifNewer: $0["ifNewer"]?.boolValue == true))) }) // action-wait-allow: answers at once; the quit follows the reply
        // The update cards' Hide and right-click choices (UPDATE-CARD-CLOSE): the card's menu runs this
        // action, and the palette offers it only while such a card shows (a disabled row is not listed).
        registry.bindEffect("updates.snooze", isEnabled: { updater.showsUpdateCloseMenu }, effect: { invocation in
            guard let option = invocation["option"]?.stringValue.flatMap(UpdateCardCloseOption.init(rawValue:)) else { return .done }
            updater.closeUpdateCard(option)
            return .done
        })
        bindNoticeRows(into: registry, updater: updater, openLink: openLink)
        // The ring return's rollback check reads the same stores as updates.rollback.
        updater.pulledWatch.stateDirectories = stateDirectories
        // Drop back (destructive: every entrypoint confirms; the CLI passes --confirm).
        registry.bind("updates.rollback", run: { [weak registry] _ in
            guard let registry else { return }
            let work = Task { await UpdateDropBack(updater).failure(to: nil, stateDirectories: stateDirectories()) }
            // task-owner: a palette or menu run nobody waits on shows a refusal; a CLI run returns it.
            if registry.isCapturingWork {
                registry.track(Task { await work.value.map { ActionWorkFailure(refusal: .unavailable, reason: $0) } })
            } else {
                Task { [weak registry] in if let why = await work.value { registry?.refuse(why) } }
            }
        })
        registry.bind("palette.switchAppChannel", unavailable: { updater.channelSwitchUnavailableReason }, invoke: { [weak registry] invocation in
            do {
                let work = try updater.switchChannel(named: invocation["channel"]?.stringValue)
                registry?.track(Task { await work.value.map { ActionWorkFailure($0) } })
            } catch {
                registry?.refuse(String(describing: error))
            }
        })
    }

    /// An update command's answer as the action's result (`action.run` `result`, or its error).
    static func result(_ answer: Task<UpdateCommandAnswer, Never>) -> ActionResultWork {
        // task-owner: the action run; ends with `answer`.
        Task {
            switch await answer.value {
            case .answered(let fields): .success(UpdateStatusAction.values(fields))
            case .refused(let reason): .failure(ActionWorkFailure(refusal: .unavailable, reason: reason))
            case .failed(let message): .failure(ActionWorkFailure(message))
            }
        }
    }
}

/// Palette rows of the sidebar's notice card, which runs these actions itself (``SidebarCardFeed/noticeAction``),
/// so the card's button and the palette row run one handler:
/// - `updates.cancelDownload`, `updates.showDetails`, `updates.releaseNotes`: the update status's Cancel, Details and
///   Release Notes buttons.
/// - `tips.muteDay`, `tips.muteWeek`: the tip card's x menu rows.
/// The palette offers each only while the notice card shows its button (a disabled row is not listed).
extension UpdateHandlers {
    /// The update status's buttons that are palette rows, by their card action.
    static let noticeRows: [(ActionID, UpdateCardAction)] = [
        ("updates.cancelDownload", .cancelDownload), ("updates.showDetails", .details), ("updates.releaseNotes", .releaseNotes),
    ]
    /// The tip card's x menu rows that are palette rows, by their menu option.
    static let tipRows: [(ActionID, TipMenuOption)] = [("tips.muteDay", .muteDay), ("tips.muteWeek", .muteWeek)]

    /// `openLink` opens the found update's release notes (a browser tab, like the card's link).
    static func bindNoticeRows(into registry: ActionRegistry, updater: UpdaterService, openLink: @escaping @MainActor (URL) -> Void) {
        for (id, action) in noticeRows {
            registry.bindEffect(id, isEnabled: { noticeShows(action, updater: updater) }, effect: { _ in
                if action == .releaseNotes {
                    if let url = updater.cardReleaseNotesURL { openLink(url) }
                } else {
                    updater.performCardAction(action)
                }
                return .done
            })
        }
        for (id, option) in tipRows {
            registry.bindEffect(id, isEnabled: { tipMenuShows(option, updater: updater) }, effect: { _ in
                if let tip = updater.tip { updater.tipCardAction(tip.id, option.rawValue) }
                return .done
            })
        }
    }

    /// Whether the sidebar's notice card is the update status with `action`'s button (or its trailing control).
    static func noticeShows(_ action: UpdateCardAction, updater: UpdaterService) -> Bool {
        guard let notice = SidebarCardFeed.noticeCard(updater, registry: nil), notice.id == SidebarCardFeed.updateCardID else { return false }
        return notice.actions.contains { $0.id == action.rawValue } || notice.trailing?.id == action.rawValue
    }

    /// Whether the sidebar's notice card is a tip whose x menu has `option`.
    static func tipMenuShows(_ option: TipMenuOption, updater: UpdaterService) -> Bool {
        guard let notice = SidebarCardFeed.noticeCard(updater, registry: nil), notice.id.hasPrefix(SidebarCardFeed.tipPrefix) else { return false }
        return notice.dismissMenu.contains { $0.id == option.rawValue }
    }
}
