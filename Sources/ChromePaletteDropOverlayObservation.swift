import AppKit
import CmuxSettings

/// Keeps an AppKit-owned drop overlay synchronized with the app-wide chrome palette.
@MainActor
final class ChromePaletteDropOverlayObservation {
    typealias UpdateStreamFactory = @MainActor @Sendable () -> AsyncStream<ChromePalette>

    private let applyPalette: @MainActor (ChromePalette) -> Void
    private let makeUpdates: UpdateStreamFactory?
    private var observationTask: Task<Void, Never>?

    init(
        overlay: NSView,
        initialPalette: ChromePalette,
        updates: UpdateStreamFactory?
    ) {
        makeUpdates = updates
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
        updates: UpdateStreamFactory?,
        apply: @escaping @MainActor (ChromePalette) -> Void
    ) {
        makeUpdates = updates
        applyPalette = apply
        applyPalette(initialPalette)
        startObserving()
    }

    deinit {
        observationTask?.cancel()
    }

    private func startObserving() {
        guard let makeUpdates else { return }
        observationTask = Task { @MainActor [weak self, makeUpdates] in
            for await palette in makeUpdates() {
                guard !Task.isCancelled else { break }
                self?.applyPalette(palette)
            }
        }
    }
}
