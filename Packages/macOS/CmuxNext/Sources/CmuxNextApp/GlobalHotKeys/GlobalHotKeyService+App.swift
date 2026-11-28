import CmuxNextFocusUI
import CmuxNextSettings

extension GlobalHotKeyService {
    /// The app's service: the catalog's global hot keys, with Show/Hide All
    /// Windows gated by `app.globalHotKey`, Start Agent from Any App by
    /// `app.startAgentGlobalHotKey` and Capture Screenshot to Chat by
    /// `app.captureScreenshotGlobalHotKey`, from the live settings.
    static func app(_ services: AppServices) -> GlobalHotKeyService {
        GlobalHotKeyService(registry: services.registry, showHideEnabled: { [weak services] in
            services?.settings?.snapshot.globalHotKey ?? CmuxConfigSnapshot.globalHotKeyDefault
        }, startAgentEnabled: { [weak services] in
            services?.settings?.snapshot.startAgentGlobalHotKey ?? CmuxConfigSnapshot.startAgentGlobalHotKeyDefault
        }, captureEnabled: { [weak services] in
            services?.settings?.snapshot.captureScreenshotGlobalHotKey ?? CmuxConfigSnapshot.captureScreenshotGlobalHotKeyDefault
        })
    }
}
