import Observation
import Foundation

/// Window-local presentation metrics shared with the small top-padding leaf.
/// The mode flag is intentionally ignored by Observation because the heavy
/// ContentView reads it as an imperative routing value; only the leaf that
/// applies safe-area padding observes the native metrics.
@MainActor
@Observable
final class WorkspacePresentationModeRuntimeCache {
    // Mutated only from ContentView's main-thread SwiftUI/AppKit callbacks; this
    // is intentionally not observable because mode changes must not invalidate
    // ContentView itself.
    @ObservationIgnored
    var isMinimalMode: Bool

    var titlebarPadding: CGFloat
    var hostingSafeAreaTop: CGFloat

    init(
        isMinimalMode: Bool = WorkspacePresentationModeSettings.isMinimal(),
        titlebarPadding: CGFloat = WindowChromeMetrics.defaultTitlebarHeight,
        hostingSafeAreaTop: CGFloat = 0
    ) {
        self.isMinimalMode = isMinimalMode
        self.titlebarPadding = titlebarPadding
        self.hostingSafeAreaTop = hostingSafeAreaTop
    }
}
