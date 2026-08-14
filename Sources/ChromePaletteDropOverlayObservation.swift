import AppKit
import CmuxSettings

/// Keeps an AppKit-owned drop overlay synchronized with the app-wide chrome palette.
@MainActor
final class ChromePaletteDropOverlayObservation: NSObject {
    private weak var overlay: NSView?

    init(overlay: NSView) {
        self.overlay = overlay
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paletteDidChange(_:)),
            name: .cmuxChromePaletteDidChange,
            object: nil
        )
        apply(AppDelegate.shared?.chromePalette
            ?? ChromePaletteRuntimeResolver(runtime: AppDelegate.shared?.settingsRuntime).resolve())
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func paletteDidChange(_ notification: Notification) {
        guard let palette = notification.object as? ChromePalette else { return }
        apply(palette)
    }

    private func apply(_ palette: ChromePalette) {
        overlay?.layer?.backgroundColor = cmuxAccentNSColor(for: palette)
            .withAlphaComponent(0.25)
            .cgColor
        overlay?.layer?.borderColor = cmuxAccentNSColor(for: palette).cgColor
    }
}
