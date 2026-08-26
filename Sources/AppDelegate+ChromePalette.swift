import CmuxSettings
import CmuxSettingsUI
import Foundation

extension AppDelegate {
    /// Installs the settings-to-window palette bridge supplied by the app root.
    @MainActor
    func configureChromePaletteRuntime(
        initialPalette: ChromePalette,
        makeUpdates: @escaping @MainActor () -> AsyncStream<ChromePalette>,
        refresh: @escaping @MainActor () -> Void
    ) {
        chromePalette = initialPalette
        makeChromePaletteUpdates = makeUpdates
        refreshChromePalette = refresh
        applyChromePaletteToOpenWindows(initialPalette)
    }

    /// Fans one resolved palette snapshot to every live window manager and
    /// AppKit portal/drop-overlay subscriber.
    @MainActor
    func applyChromePaletteToOpenWindows(_ palette: ChromePalette) {
        chromePalette = palette
        tabManager?.applyChromePalette(palette)
        for context in mainWindowContexts.values {
            context.tabManager.applyChromePalette(palette)
        }
    }
}
