public import Foundation

/// A capability a page asked for.
public nonisolated enum BrowserPermissionKind: Hashable, Sendable {
    case camera
    case microphone
    case cameraAndMicrophone
}

/// What a prompt asks the user.
public nonisolated enum BrowserPromptKind: Hashable, Sendable {
    case permission(BrowserPermissionKind)
    case alert(message: String)
    case confirm(message: String)
    case textInput(message: String, defaultText: String?)
}

/// The user's answer to a prompt.
public nonisolated enum BrowserPromptResponse: Hashable, Sendable {
    case allow
    case deny
    /// Alert or confirm accepted.
    case accept
    /// Confirm or text input cancelled.
    case cancel
    case text(String)
}
