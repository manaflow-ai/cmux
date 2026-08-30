import AppKit
import CmuxSettings

/// Keeps an AppKit-owned drop overlay synchronized with the app-wide chrome palette.
@MainActor
final class ChromePaletteDropOverlayObservation {
    private let applyPalette: @MainActor (ChromePalette) -> Void
    private let updates: ChromePaletteUpdateSource?
    private var observationTask: Task<Void, Never>?

    init(
        overlay: NSView,
        initialPalette: ChromePalette,
        updates: ChromePaletteUpdateSource?
    ) {
        self.updates = updates
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
        updates: ChromePaletteUpdateSource?,
        apply: @escaping @MainActor (ChromePalette) -> Void
    ) {
        self.updates = updates
        applyPalette = apply
        applyPalette(initialPalette)
        startObserving()
    }

    deinit {
        observationTask?.cancel()
    }

    private func startObserving() {
        guard let updates else { return }
        observationTask = Task { @MainActor [weak self, updates] in
            for await palette in updates.makeStream() {
                guard !Task.isCancelled else { break }
                self?.applyPalette(palette)
            }
        }
    }
}
