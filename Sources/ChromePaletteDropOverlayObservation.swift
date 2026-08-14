import AppKit
import CmuxSettings

/// Keeps an AppKit-owned drop overlay synchronized with the app-wide chrome palette.
@MainActor
final class ChromePaletteDropOverlayObservation {
    private let applyPalette: @MainActor (ChromePalette) -> Void
    private var observationTask: Task<Void, Never>?

    init(overlay: NSView) {
        let initialPalette = AppDelegate.shared?.chromePalette
            ?? ChromePaletteRuntimeResolver(runtime: AppDelegate.shared?.settingsRuntime).resolve()
        applyPalette = { [weak overlay] palette in
            overlay?.layer?.backgroundColor = palette.cmuxAccentNSColor
                .withAlphaComponent(0.25)
                .cgColor
            overlay?.layer?.borderColor = palette.cmuxAccentNSColor.cgColor
        }
        applyPalette(initialPalette)
        startObserving()
    }

    init(
        initialPalette: ChromePalette,
        apply: @escaping @MainActor (ChromePalette) -> Void
    ) {
        applyPalette = apply
        applyPalette(initialPalette)
        startObserving()
    }

    deinit {
        observationTask?.cancel()
    }

    private func startObserving() {
        observationTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .cmuxChromePaletteDidChange
            )
            for await notification in notifications {
                guard !Task.isCancelled else { break }
                guard let palette = notification.object as? ChromePalette else { continue }
                self?.applyPalette(palette)
            }
        }
    }
}
