#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileTerminal

/// Coalesces SwiftUI update passes into one surface-local Ghostty theme update.
@MainActor
final class TerminalThemeApplicationScheduler {
    private var applicationTask: Task<Void, Never>?
    private var pendingGeneration: UInt64?
    private(set) var lastAppliedGeneration: UInt64 = 0

    func seed(generation: UInt64) {
        lastAppliedGeneration = generation
    }

    func schedule(
        _ theme: TerminalTheme,
        generation: UInt64,
        to surfaceView: GhosttySurfaceView
    ) {
        guard generation != lastAppliedGeneration,
              generation != pendingGeneration else { return }
        applicationTask?.cancel()
        pendingGeneration = generation
        applicationTask = Task { @MainActor [weak self, weak surfaceView] in
            await Task.yield()
            guard !Task.isCancelled, let self, let surfaceView else { return }
            guard self.pendingGeneration == generation else { return }
            self.lastAppliedGeneration = generation
            self.pendingGeneration = nil
            GhosttyRuntime.applyTheme(theme, to: surfaceView)
            self.applicationTask = nil
        }
    }

    func cancel() {
        applicationTask?.cancel()
        applicationTask = nil
        pendingGeneration = nil
    }
}
#endif
