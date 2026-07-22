/// Reports the terminal result of one WebExtension loading attempt.
public enum BrowserWebExtensionLoadOutcome: Equatable, Sendable {
    /// Every load operation completed, including isolated extension failures.
    case ready

    /// The runtime remains usable for navigation with reduced extension support.
    case degraded(BrowserWebExtensionFailure)
}
