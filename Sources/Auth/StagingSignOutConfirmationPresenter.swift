import AppKit

/// Presents the per-environment sign-out warning: signing out on a
/// non-production environment returns this Mac to Production (restoring the
/// parked Production session), so the user must confirm before the chain
/// runs.
///
/// Injected into ``HostAccountFlow`` as its `confirmStagingSignOut` seam so
/// the interception at the `signOut()` choke point is testable with a fake;
/// this type is the production presenter. `NSAlert.runModal()` blocks the
/// main run loop by design — the confirmation is intentionally modal, like
/// every destructive-action alert in the app.
@MainActor
struct StagingSignOutConfirmationPresenter {
    /// Present the alert and report whether the user confirmed.
    func confirmStagingSignOut() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "settings.account.stagingSignOut.title",
            defaultValue: "Sign out and return to Production?"
        )
        alert.informativeText = String(
            localized: "settings.account.stagingSignOut.message",
            defaultValue: "Signing out here signs you out of Staging and returns this Mac to Production, restoring your saved Production session."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "settings.account.stagingSignOut.confirm",
            defaultValue: "Sign Out"
        ))
        alert.addButton(withTitle: String(
            localized: "settings.account.stagingSignOut.cancel",
            defaultValue: "Cancel"
        ))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
