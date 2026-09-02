import AppKit
import Foundation

/// A failed file drop used to be a beep and nothing else, even though the error
/// already carried a usable reason: the built-in transport's localized message,
/// or — for a `terminal.uploadCommands` rule — the stderr of the command that
/// failed. Both were built and then dropped on the floor, so an upload that
/// stopped working looked identical to one that had never been configured.
///
/// This turns that reason into a notification. Callers beep only when the
/// notification could not be delivered: the store plays its own sound according
/// to the user's notification settings, so beeping alongside it would double
/// the sound, and a failure that is deliberately not reported (cancellation)
/// must stay silent.
enum TerminalUploadFailureNotification {
    /// Longest reason we will show, in unicode scalars. Counting scalars rather
    /// than Characters matters: a Character is a grapheme cluster, so one base
    /// character followed by thousands of combining marks counts as 1 and would
    /// let most of the captured stderr through a Character-based cap.
    static let maximumDetailScalars = 400

    struct Payload: Equatable {
        let title: String
        let subtitle: String
        let body: String
        /// Scoped to the surface so a failure in one pane cannot silence an
        /// unrelated failure in another during the cooldown window.
        let cooldownKey: String
    }

    /// What became of a failure handed to ``post(error:surfaceId:)``.
    enum Outcome: Equatable {
        /// A notification was added to the store.
        case posted
        /// Nothing to say (cancellation, or an error with no message). The
        /// silence is intentional; the caller must not beep.
        case suppressed
        /// There was a reason to show but no way to show it: no store, no
        /// workspace to anchor to, or the per-surface cooldown swallowed it.
        /// The caller should fall back to a beep.
        case unavailable
    }

    static let cooldownInterval: TimeInterval = 5

    /// The reason to show for `error`, or nil when there is nothing worth
    /// saying. Cancellation returns nil: the user stopped the upload, so
    /// telling them it stopped is noise.
    static func detail(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let executionError = error as? TerminalImageTransferExecutionError,
           case .cancelled = executionError {
            return nil
        }

        let described = sanitized(error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !described.isEmpty else { return nil }
        return truncated(described)
    }

    /// Drops C0 control characters and DEL. The text comes from a process's
    /// stderr, and terminal escape sequences have no business in a
    /// notification body. Newlines and tabs are kept as spaces so a multi-line
    /// reason still reads.
    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar {
            case "\n", "\r", "\t": return " "
            default: return (scalar.value < 0x20 || scalar.value == 0x7f) ? " " : scalar
            }
        }))
    }

    /// Trims to `maximumDetailScalars`, marking the cut so a reader can tell the
    /// message was shortened rather than the command having stopped mid-word.
    static func truncated(_ detail: String) -> String {
        let scalars = detail.unicodeScalars
        guard scalars.count > maximumDetailScalars else { return detail }
        let kept = String(String.UnicodeScalarView(scalars.prefix(maximumDetailScalars - 1)))
        return kept + "…"
    }

    /// Everything the notification says, or nil when the failure is not worth
    /// reporting. Pure, so a test can assert the body without an app host.
    static func payload(for error: Error, surfaceId: UUID?) -> Payload? {
        guard let detail = detail(for: error) else { return nil }
        return Payload(
            title: String(
                localized: "notification.terminalUpload.failed.title",
                defaultValue: "Couldn't upload the dropped file"
            ),
            subtitle: String(
                localized: "notification.terminalUpload.failed.subtitle",
                defaultValue: "Nothing was typed into the terminal"
            ),
            body: detail,
            cooldownKey: "terminal-upload-failed.\(surfaceId?.uuidString ?? "unanchored")"
        )
    }

    /// Posts the failure against the workspace owning `surfaceId`.
    ///
    /// `surfaceId` must be the surface the upload STARTED on, captured before
    /// the transfer, not read back in the completion: a view can be reattached
    /// to a different surface while the upload runs.
    @MainActor
    @discardableResult
    static func post(error: Error, surfaceId: UUID?) -> Outcome {
        guard let payload = payload(for: error, surfaceId: surfaceId) else { return .suppressed }
        guard let appDelegate = AppDelegate.shared,
              let notificationStore = appDelegate.notificationStore else { return .unavailable }

        // Anchor to the workspace that owns the originating surface. If that
        // surface is gone the id is dropped too, so the notification is filed
        // against the focused workspace rather than being retargeted away from
        // a surface that no longer exists.
        let owningWorkspaceId = surfaceId
            .flatMap { appDelegate.workspaceContainingPanel(panelId: $0)?.workspace.id }
        let anchoredSurfaceId = owningWorkspaceId == nil ? nil : surfaceId
        guard let tabId = owningWorkspaceId
            ?? appDelegate.activeTabManagerForCommands(preferredWindow: nil)?.selectedTabId
        else { return .unavailable }

        // The store reports nothing back and silently drops a notification
        // whose cooldown key is still active, so the only way to know whether
        // this one landed is to look.
        let countBefore = notificationStore.notifications.count
        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: anchoredSurfaceId,
            title: payload.title,
            subtitle: payload.subtitle,
            body: payload.body,
            cooldownKey: payload.cooldownKey,
            cooldownInterval: cooldownInterval
        )
        return notificationStore.notifications.count > countBefore ? .posted : .unavailable
    }
}
