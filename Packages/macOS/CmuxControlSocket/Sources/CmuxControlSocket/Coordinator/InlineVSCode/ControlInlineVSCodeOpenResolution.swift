public import Foundation

/// The app-side outcome of queueing an inline VS Code open request.
public enum ControlInlineVSCodeOpenResolution: Sendable, Equatable {
    /// The requested path does not exist.
    case directoryNotFound
    /// The requested path exists but is not a directory.
    case notDirectory
    /// Bounded filesystem validation could not complete.
    case validationUnavailable
    /// No tab manager matched the routing selectors.
    case tabManagerUnavailable
    /// An explicit workspace selector did not match the routed window.
    case workspaceNotFound
    /// A compatible VS Code installation is unavailable.
    case vscodeUnavailable
    /// The inline server/open request could not be started.
    case openFailed
    /// The asynchronous inline server/open request was queued successfully.
    case accepted(windowID: UUID?, workspaceID: UUID)
}
