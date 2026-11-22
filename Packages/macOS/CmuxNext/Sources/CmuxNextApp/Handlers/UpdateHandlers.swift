import CmuxNextActions
import CmuxNextUpdater

/// Update actions (menu, palette, shortcut, CLI `settings check-for-updates`
/// etc.) over the one `UpdaterService`. Checks always run: release builds
/// use Sparkle, DEV builds probe the feed read-only. Install and channel
/// switch are disabled, with the reason, where they cannot run.
enum UpdateHandlers {
    static func bind(into registry: ActionRegistry, updater: UpdaterService, openWhatsNew: @escaping @MainActor () -> Bool = { false }) {
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
