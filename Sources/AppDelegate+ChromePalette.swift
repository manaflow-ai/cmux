import CmuxSettings
import CmuxSettingsUI
import Foundation

extension AppDelegate {
    /// The current app-wide chrome palette for AppKit and web-backed chrome.
    var chromePalette: ChromePalette {
        chromePaletteRuntimeCoordinator?.palette
            ?? tabManager?.chromePalette
            ?? ChromePaletteRuntimeResolver(runtime: settingsRuntime).resolve()
    }

    /// Creates the single settings-to-window palette bridge at app startup.
    @MainActor
    func configureChromePaletteRuntime(runtime: SettingsRuntime) {
        let coordinator = ChromePaletteRuntimeCoordinator(runtime: runtime) { [weak self] palette in
            self?.applyChromePaletteToOpenWindows(palette)
        }
        chromePaletteRuntimeCoordinator = coordinator
        applyChromePaletteToOpenWindows(coordinator.palette)
        coordinator.start()
    }

    /// Fans one resolved palette snapshot to every live window manager and
    /// AppKit portal/drop-overlay subscriber.
    @MainActor
    func applyChromePaletteToOpenWindows(_ palette: ChromePalette) {
        tabManager?.applyChromePalette(palette)
        for context in mainWindowContexts.values {
            context.tabManager.applyChromePalette(palette)
        }
        NotificationCenter.default.post(name: .cmuxChromePaletteDidChange, object: palette)
    }
}
