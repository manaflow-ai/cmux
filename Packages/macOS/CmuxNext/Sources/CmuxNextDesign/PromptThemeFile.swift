import CmuxNextCompat
import CmuxTheme
import Foundation

/// Leaves the theme's prompt colors (``PromptTheme``) where cmux Remote reads them, so the prompts it shows over
/// every app (a device asking to see or control this Mac, an agent asking to use an app) wear the app's theme and
/// glass, as the app's own floating prompts do (``SurfaceRole/prompt``). One cmux Remote serves every build, so only
/// a build on the shared paths writes it: a DEV build or a state root (``BuildStatePaths/ownsState``) leaves
/// NIGHTLY's look alone. A write is one small file off the main thread, on a theme change only.
nonisolated enum PromptThemeFile {
    /// Writes `tokens`' prompt colors (nothing under tests, a DEV build or a state root).
    static func publish(_ tokens: ThemeTokens) {
        guard !BuildStatePaths.current.ownsState,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let url = PromptTheme.defaultURL, let data = try? PromptTheme(tokens: tokens).encoded() else { return }
        // task-owner: one small atomic write per theme change; a later change's write replaces it on disk
        Task.detached(priority: .utility) {
            try? FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.blockingWrite(to: url, options: .atomic)
        }
    }
}
