/// What an activation request for the Cloud Tunnel extension reported.
public enum SystemExtensionActivationEvent: Sendable, Equatable {
    /// macOS waits for the user in System Settings; a later event follows.
    case needsApproval
    /// The extension is active (installed, or an older copy replaced).
    case activated
    /// Active after the next restart.
    case willCompleteAfterReboot
    /// The request failed; the text is the system's reason.
    case failed(String)
}

/// Submits `OSSystemExtensionRequest` activation requests. A seam so the controller is tested
/// without SystemExtensions; ``LiveSystemExtensionActivator`` is the real one.
@MainActor
public protocol SystemExtensionActivating: AnyObject {
    /// Requests activation of the bundled extension `identifier`, replacing any older copy.
    ///
    /// - Returns: The request's events; the stream ends after a final one (``SystemExtensionActivationEvent/activated``,
    ///   ``SystemExtensionActivationEvent/willCompleteAfterReboot`` or ``SystemExtensionActivationEvent/failed(_:)``).
    func activate(identifier: String) -> AsyncStream<SystemExtensionActivationEvent>
}
