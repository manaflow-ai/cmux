import CmuxNextCompat
import CmuxTheme
import Foundation

/// Leaves the theme's prompt colors (``PromptTheme``) where cmux Remote reads them, so the prompts it shows over
/// every app (a device asking to see or control this Mac, an agent asking to use an app) wear the app's theme and
/// glass, as the app's own floating prompts do (``SurfaceRole/prompt``). One cmux Remote serves every build, so only
/// a build on the shared paths writes it: a DEV build or a state root (``BuildStatePaths/ownsState``) leaves
/// NIGHTLY's look alone. A write is one small file off the main thread, on a theme change only.
nonisolated enum PromptThemeFile {
    private static let queue = DispatchQueue(label: "cmux.prompt-theme-file", qos: .utility)

    /// Writes `tokens`' prompt colors (nothing under tests, a DEV build or a state root).
    static func publish(_ tokens: ThemeTokens) {
        guard !BuildStatePaths.current.ownsState,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let url = PromptTheme.defaultURL else { return }
        let theme = PromptTheme(tokens: tokens)
        queue.async { try? theme.write(to: url) }
    }
}
