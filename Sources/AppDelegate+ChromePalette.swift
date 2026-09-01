import CmuxSettings
import CmuxSettingsUI
import Foundation

extension AppDelegate {
    /// Installs the palette coordinator supplied by the app composition root.
    @MainActor
    func configureChromePaletteRuntime(_ coordinator: ChromePaletteRuntimeCoordinator) {
        chromePaletteRuntimeCoordinator = coordinator
        applyChromePaletteToOpenWindows(coordinator.palette)
    }

    /// Fans one resolved palette snapshot to every live window manager and
    /// AppKit portal/drop-overlay subscriber.
    @MainActor
    func applyChromePaletteToOpenWindows(_ palette: ChromePalette) {
        tabManager?.applyChromePalette(palette)
        for context in mainWindowContexts.values {
            context.tabManager.applyChromePalette(palette)
        }
    }

    /// Returns the latest immutable palette for an AppKit presentation seam.
    ///
    /// Early construction can precede coordinator injection (for example a
    /// debug window created during delegate startup), so the resolver fallback
    /// remains deterministic and does not store a second mutable snapshot.
    @MainActor
    func chromePaletteSnapshot() -> ChromePalette {
        chromePaletteRuntimeCoordinator?.palette
            ?? ChromePaletteRuntimeResolver(runtime: settingsRuntime).resolve()
    }

    /// Creates an independent update source for one AppKit/SwiftUI consumer.
    @MainActor
    func makeChromePaletteUpdateSource() -> ChromePaletteUpdateSource? {
        guard let coordinator = chromePaletteRuntimeCoordinator else { return nil }
        return ChromePaletteUpdateSource(streamFactory: {
            coordinator.makeUpdateStream()
        })
    }
}
