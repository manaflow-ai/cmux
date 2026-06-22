/// The fully-assembled close-confirmation dialog the
/// ``WorkspaceCloseCoordinator`` hands to the app-side ``CloseConfirming``
/// witness to present. The coordinator owns the WHOLE decision — which dialog,
/// the assembled message text (`String(format:)` over the witness-supplied
/// localized pieces), and whether the "Don't ask again" suppression checkbox is
/// shown — so the witness only builds and runs the `NSAlert` and reports the
/// outcome.
///
/// **Why the strings arrive pre-assembled.** `String(localized:)` must resolve
/// in the app bundle (the package bundle lacks the keys), so the witness still
/// supplies the localized title/message/format/button strings through
/// ``CloseConfirming``. The coordinator then performs the `String(format:)` /
/// `String.localizedStringWithFormat` substitution and the which-variant choice
/// that the legacy `confirmAnchorWorkspaceClose` / `confirmPinnedWorkspaceClose`
/// bodies did inline, so the assembly leaves the god file and lives next to the
/// decision logic.
public struct CloseConfirmationPrompt: Sendable, Equatable {
    /// The alert title (`NSAlert.messageText`).
    public let title: String
    /// The alert body (`NSAlert.informativeText`).
    public let message: String
    /// Whether the alert accepts Cmd-D as confirm (legacy `acceptCmdD`). The
    /// witness records it for telemetry; the shared modal presenter does not
    /// otherwise consume it, matching the legacy `_ = acceptCmdD`.
    public let acceptCmdD: Bool
    /// Whether the alert shows the "Don't ask again" suppression checkbox (only
    /// the anchor-close dialog does). When true the outcome reports whether the
    /// user checked it.
    public let showsSuppressionCheckbox: Bool

    /// Creates a resolved confirmation prompt.
    public init(
        title: String,
        message: String,
        acceptCmdD: Bool,
        showsSuppressionCheckbox: Bool
    ) {
        self.title = title
        self.message = message
        self.acceptCmdD = acceptCmdD
        self.showsSuppressionCheckbox = showsSuppressionCheckbox
    }
}
