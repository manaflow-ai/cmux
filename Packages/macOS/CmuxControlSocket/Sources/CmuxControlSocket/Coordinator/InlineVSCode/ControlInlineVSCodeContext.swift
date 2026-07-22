/// The inline-VS-Code-domain slice of the control-command seam.
@MainActor
public protocol ControlInlineVSCodeContext: AnyObject {
    /// Returns messages resolved from the app's localization catalog.
    ///
    /// `nonisolated` because the worker-lane coordinator shapes validation and
    /// routing errors without occupying the main actor.
    nonisolated func controlInlineVSCodeStrings() -> ControlInlineVSCodeStrings

    /// Queues an absolute directory path for cmux's inline VS Code browser pane.
    ///
    /// The return value reports whether the asynchronous serve-web request was
    /// accepted. It does not claim the server or browser pane has finished
    /// opening.
    func controlInlineVSCodeOpen(
        routing: ControlRoutingSelectors,
        directoryPath: String
    ) -> ControlInlineVSCodeOpenResolution
}
