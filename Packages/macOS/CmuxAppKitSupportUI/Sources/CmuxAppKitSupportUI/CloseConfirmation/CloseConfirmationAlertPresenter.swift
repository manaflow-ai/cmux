public import AppKit
public import CmuxWorkspaces

/// Builds and runs the workspace close-confirmation `NSAlert`, returning a
/// ``CmuxWorkspaces/CloseConfirmationOutcome``.
///
/// This is the AppKit presentation half of the close-confirmation seam. The
/// `WorkspaceCloseCoordinator` owns the whole decision (which dialog, the
/// assembled message text, whether the suppression checkbox shows); the app-side
/// `CloseConfirming` witness resolves the localized strings (`String(localized:)`
/// must bind to the app bundle) and the presenting window, then hands both to
/// this presenter. The presenter performs only the self-contained AppKit
/// ceremony: configuring the alert, wiring the Close / Cancel buttons and their
/// key equivalents, attaching the optional "Don't ask again" checkbox, running
/// the modal, and mapping the response to the outcome.
///
/// **Why the modal run is injected.** The shared cmux modal presenter
/// (`runCmuxModalAlert`, which activates the app and prefers a sheet on the main
/// window) and the DEBUG UITest telemetry both live in the app target, so the
/// caller injects a ``ModalRunner`` that runs the configured alert against the
/// resolved window and reports the presentation path it took. The presenter never
/// reaches for `NSApp`, window resolution, or telemetry itself.
///
/// **Why synchronous.** The modal blocks the run loop and returns the user's
/// answer in the same `@MainActor` turn; the batch-close loop relies on that to
/// abort the whole batch when a dialog is cancelled. Matches the legacy
/// `confirmClose` timing exactly.
@MainActor
public final class CloseConfirmationAlertPresenter {
    /// Runs a fully-configured confirmation alert against `presentingWindow` and
    /// returns the modal response.
    ///
    /// The app conforms this to the shared `runCmuxModalAlert` presenter, which
    /// activates the app and presents the alert as a sheet on the main cmux
    /// window when one is available (falling back to app-modal otherwise) and
    /// records the DEBUG presentation-path telemetry from the path it actually
    /// takes.
    public typealias ModalRunner = @MainActor (NSAlert, NSWindow?) -> NSApplication.ModalResponse

    private let runModal: ModalRunner

    /// Creates a presenter that runs alerts through `runModal`.
    ///
    /// - Parameter runModal: The injected modal runner, normally the app's
    ///   `runCmuxModalAlert` wrapper carrying the window-resolution and DEBUG
    ///   telemetry that must stay app-side.
    public init(runModal: @escaping ModalRunner) {
        self.runModal = runModal
    }

    /// Builds and presents `prompt` modally against `presentingWindow` and
    /// reports the outcome.
    ///
    /// Mirrors the legacy `confirmClose` / `confirmAnchorWorkspaceClose` alert
    /// construction one-for-one: warning style, Close (default, Return) and
    /// Cancel (Escape) buttons, an optional unchecked "Don't ask again" checkbox
    /// accessory, then the injected modal run. The outcome's `confirmed` reflects
    /// the first-button response and `suppressionChecked` is only ever `true`
    /// when the prompt showed the checkbox, the user confirmed, and the box was on.
    ///
    /// - Parameters:
    ///   - prompt: The resolved dialog (title, message, checkbox flag) from the
    ///     coordinator.
    ///   - buttonStrings: The localized Close / Cancel / "Don't ask again"
    ///     labels, resolved app-side.
    ///   - presentingWindow: The host window the caller resolved app-side, passed
    ///     through to the injected runner for sheet anchoring.
    public func present(
        _ prompt: CloseConfirmationPrompt,
        buttonStrings: CloseConfirmationButtonStrings,
        presentingWindow: NSWindow?
    ) -> CloseConfirmationOutcome {
        _ = prompt.acceptCmdD

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: buttonStrings.close)
        alert.addButton(withTitle: buttonStrings.cancel)

        let suppressionButton: NSButton?
        if prompt.showsSuppressionCheckbox {
            let button = NSButton(
                checkboxWithTitle: buttonStrings.dontAskAgain,
                target: nil,
                action: nil
            )
            button.state = .off
            alert.accessoryView = button
            suppressionButton = button
        } else {
            suppressionButton = nil
        }

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        let confirmed = runModal(alert, presentingWindow) == .alertFirstButtonReturn
        return CloseConfirmationOutcome(
            confirmed: confirmed,
            suppressionChecked: confirmed && (suppressionButton?.state == .on)
        )
    }
}
