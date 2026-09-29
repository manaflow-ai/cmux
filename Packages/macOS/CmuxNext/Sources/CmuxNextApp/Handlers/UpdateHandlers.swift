import CmuxNextActions
import CmuxNextUpdater

/// Update actions (menu, palette, shortcut, CLI `settings check-for-updates`
/// etc.) over the one `UpdaterService`. Checks always run: release builds
/// use Sparkle, DEV builds probe the feed read-only. Install and channel
/// switch are disabled, with the reason, where they cannot run.
enum UpdateHandlers {
    static func bind(into registry: ActionRegistry, updater: UpdaterService) {
        registry.bind("palette.checkForUpdates", run: { [weak registry] _ in
            // `action.run --wait` answers after a probe has its result.
            if let work = updater.checkForUpdates() { registry?.track(work) }
        })
        for id: ActionID in ["palette.applyUpdateIfAvailable", "palette.attemptUpdate"] {
            registry.bind(id, unavailable: { updater.installUnavailableReason }, invoke: { [weak registry] _ in
                do { try updater.installAvailableUpdate() } catch { registry?.refuse(String(describing: error)) }
            })
        }
        registry.bind("palette.switchAppChannel", unavailable: { updater.channelSwitchUnavailableReason }, invoke: { [weak registry] invocation in
            do {
                registry?.track(try updater.switchChannel(named: invocation["channel"]?.stringValue))
            } catch {
                registry?.refuse(String(describing: error))
            }
        })
    }
}
