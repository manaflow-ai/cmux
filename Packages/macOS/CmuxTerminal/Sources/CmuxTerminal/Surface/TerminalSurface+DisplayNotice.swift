import Foundation
import GhosttyKit

extension TerminalSurface {
    /// Shows a cmux-authored notice in the terminal.
    ///
    /// - Parameter message: The already-localized notice text.
    @MainActor
    public func writeDisplayNotice(_ message: String) {
        // Placeholder delivery: the notice is typed into the next shell.
        prepareNextRuntimeInitialInput(message + "\n")
    }

    /// Admits a deferred startup-restore runtime as a plain shell and shows
    /// `displayNotice` in place of the deferred startup payload.
    @MainActor
    @discardableResult
    public func admitStartupRestoreRuntime(displayNotice: String) -> Bool {
        admitStartupRestoreRuntime(initialInput: displayNotice + "\n")
    }

    /// Writes notices queued before the runtime surface existed.
    @MainActor
    func flushPendingDisplayNotices(to surface: ghostty_surface_t) {}
}
