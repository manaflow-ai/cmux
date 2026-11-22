import CmuxNextActions
import CmuxNextUpdater
import Foundation

/// Update actions (menu, palette, shortcut, CLI `settings check-for-updates`
/// etc.) over the one `UpdaterService`. Checks always run: release builds
/// use Sparkle, DEV builds probe the feed read-only. Install and channel
/// switch are disabled, with the reason, where they cannot run.
enum UpdateHandlers {
    static func bind(into registry: ActionRegistry, updater: UpdaterService, openWhatsNew: @escaping @MainActor () -> Bool = { false },
                     whatsNewUnavailable: @escaping @MainActor () -> String? = { nil },
                     stateDirectories: @escaping @MainActor () -> [URL?] = { [nil] }) {
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
            case .answered(let fields):
                .success(fields.mapValues { field in
                    switch field {
                    case .string(let text): .string(text)
                    case .bool(let flag): .bool(flag)
                    case .double(let number): .double(number)
                    }
                })
            case .refused(let reason): .failure(ActionWorkFailure(refusal: .unavailable, reason: reason))
            case .failed(let message): .failure(ActionWorkFailure(message))
            }
        }
    }
}
