import AppKit
import CmuxWorkspaces

/// The app-side ``CloseConfirming`` witness driven by
/// ``WorkspaceCloseCoordinator``: it resolves the localized confirmation
/// strings (so `String(localized:)` binds to the app bundle, not the package
/// bundle, preserving non-English translations) and builds + runs the
/// confirmation `NSAlert` through the shared `runCmuxModalAlert` presenter.
///
/// The whole confirmation decision (re-entrancy session flag, test-override
/// handler, anchor-suppression read/write, which-dialog / which-message choice,
/// and the `String(format:)` assembly) lives in ``WorkspaceCloseCoordinator``;
/// this presenter only performs the two halves that must stay app-side. Lifted
/// verbatim from the per-window `TabManager`'s former in-class conformance,
/// itself lifted from the legacy `confirmClose` / `confirmAnchorWorkspaceClose`
/// alert construction.
///
/// The only live-state coupling is the modal's preferred host window. The owning
/// `TabManager` supplies it through ``attach(presentingWindow:)`` as a closure
/// that reads its own (weak, mutable) `window`, so the presenter resolves the
/// current window at present-time exactly as the in-class path did.
@MainActor
final class WorkspaceCloseConfirmationPresenter: CloseConfirming {
    /// Resolves the `TabManager`'s own owning window to prefer when presenting
    /// the modal. Supplied by ``attach(presentingWindow:)`` after the owning
    /// `TabManager` is fully initialized; `nil` until then (the coordinator only
    /// calls `present` after attach, so the closure is always set in practice).
    private var presentingWindowProvider: (@MainActor () -> NSWindow?)?

    /// Wires the preferred-host-window source. Called once by the owning
    /// `TabManager` during construction, after all of its stored properties are
    /// initialized, so the closure can safely capture it weakly.
    func attach(presentingWindow provider: @escaping @MainActor () -> NSWindow?) {
        presentingWindowProvider = provider
    }

    func present(_ prompt: CloseConfirmationPrompt) -> CloseConfirmationOutcome {
        _ = prompt.acceptCmdD

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        let suppressionButton: NSButton?
        if prompt.showsSuppressionCheckbox {
            let button = NSButton(
                checkboxWithTitle: String(
                    localized: "dialog.dontAskAgain",
                    defaultValue: "Don\u{2019}t ask again"
                ),
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

        #if DEBUG
        UITestRecorder.record([
            "closeConfirmationTitle": prompt.title,
            "closeConfirmationMessage": prompt.message,
        ])
        #endif

        let confirmed = runCloseConfirmationAlert(alert) == .alertFirstButtonReturn
        return CloseConfirmationOutcome(
            confirmed: confirmed,
            suppressionChecked: confirmed && (suppressionButton?.state == .on)
        )
    }

    func closeWorkspacesTitle(willCloseWindow: Bool) -> String {
        willCloseWindow
            ? String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
            : String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
    }

    func closeWorkspacesMessage(
        willCloseWindow: Bool,
        workspaceCount: Int,
        bulletedTitles: String
    ) -> String {
        let format = willCloseWindow
            ? String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            )
            : String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            )
        return String(format: format, locale: .current, Int64(workspaceCount), bulletedTitles)
    }

    var workspaceDisplayTitleFallback: String {
        String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    }

    var closeWorkspaceTitle: String {
        String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?")
    }

    var closeWorkspaceMessage: String {
        String(
            localized: "dialog.closeWorkspace.message",
            defaultValue: "This will close the workspace and all of its panels."
        )
    }

    var closePinnedWorkspaceTitle: String {
        String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?")
    }

    var closePinnedWorkspaceMessage: String {
        String(
            localized: "dialog.closePinnedWorkspace.message",
            defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
        )
    }

    var closeAnchorTitle: String {
        String(localized: "dialog.closeAnchor.title", defaultValue: "Close this workspace?")
    }

    var closeAnchorMessageLoneFormat: String {
        String(
            localized: "dialog.closeAnchor.message.lone",
            defaultValue: "Closing this workspace will remove the group \u{201C}%@\u{201D}."
        )
    }

    var closeAnchorMessageOneFormat: String {
        String(
            localized: "dialog.closeAnchor.message.one",
            defaultValue: "Closing this workspace will ungroup \u{201C}%@\u{201D} and release 1 other workspace."
        )
    }

    var closeAnchorMessageManyFormat: String {
        String(
            localized: "dialog.closeAnchor.message.many",
            defaultValue: "Closing this workspace will ungroup \u{201C}%1$@\u{201D} and release %2$lld other workspaces."
        )
    }

    private func runCloseConfirmationAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // Presentation (activate + sheet-on-main-window, else app-modal) is
        // shared with every other cmux dialog via `runCmuxModalAlert`. This
        // wrapper only adds the close-confirmation-specific UITest telemetry,
        // recorded from the presenter's actual path so the label can never
        // disagree with how the alert was really shown.
        return runCmuxModalAlert(
            alert,
            presentingWindow: closeConfirmationPresentingWindow()
        ) { presentation in
            #if DEBUG
            switch presentation {
            case .sheet(let hostWindow):
                // The sheet attaches after this hook returns, so read the
                // attachment on the next runloop turn (during the modal loop).
                DispatchQueue.main.async {
                    UITestRecorder.record([
                        "closeConfirmationPresentation": "sheet",
                        "closeConfirmationAttachedSheet": hostWindow.attachedSheet == nil ? "0" : "1",
                    ])
                }
            case .appModal(let hostWindowHadAttachedSheet):
                UITestRecorder.record([
                    "closeConfirmationPresentation": "appModal",
                    "closeConfirmationAttachedSheet": hostWindowHadAttachedSheet ? "1" : "0",
                ])
            }
            #endif
        }
    }

    private func closeConfirmationPresentingWindow() -> NSWindow? {
        cmuxMainWindowForModalPresentation(preferring: presentingWindowProvider?())
    }
}
