import CmuxNextActions
import CmuxNextUpdater
import Foundation

/// Update actions (menu, palette, shortcut, CLI `settings check-for-updates`
/// etc.) over the one `UpdaterService`. Checks always run: release builds
/// use Sparkle, DEV builds probe the feed read-only. Install and channel
/// switch are disabled, with the reason, where they cannot run.
enum UpdateHandlers {
    static func bind(into registry: ActionRegistry, updater: UpdaterService, openWhatsNew: @escaping @MainActor () -> Bool = { false },
                     stateDirectories: @escaping @MainActor () -> [URL?] = { [nil] }) {
        // The What's New top page (WHATS-NEW-AFTER-UPDATE): palette, Help menu, CLI.
        registry.bind("updates.whatsNew", run: { _ in _ = openWhatsNew() })
        // announcements.enabled through the one setting path (palette.toggleSetting).
        for (id, on) in [("announcements.show", true), ("announcements.hide", false)] {
            registry.bind(ActionID(rawValue: id), run: { [weak registry] invocation in
                _ = registry?.perform("palette.toggleSetting", invocation: ActionInvocation(
                    arguments: ["setting": .string("announcements.enabled"), "on": .bool(on)], origin: invocation.origin))
            })
        }
        // Not tracked for `action.run wait`: a feed fetch can outlast the 2 s
        // control deadline. `updates.check` / `updates.status` carry the result.
        registry.bind("palette.checkForUpdates", run: { _ in updater.checkForUpdates() })
        for id: ActionID in ["palette.applyUpdateIfAvailable", "palette.attemptUpdate"] {
            registry.bind(id, unavailable: { updater.installUnavailableReason }, invoke: { [weak registry] _ in
                do { try updater.installAvailableUpdate() } catch { registry?.refuse(String(describing: error)) }
            })
        }
        // The pulled-build banner's Roll Back: the same stores, and the same question as updates.rollback.
        updater.pulledWatch.stateDirectories = stateDirectories
        updater.pulledWatch.confirmRollBack = { [weak registry] proceed in registry?.confirmationPresenter?("updates.rollback", ActionInvocation()) { _ in proceed() } }
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
}
