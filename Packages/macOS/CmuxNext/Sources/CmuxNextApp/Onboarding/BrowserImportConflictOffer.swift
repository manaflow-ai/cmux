import AppKit
import CmuxNextDesign

/// Import from Browser never overwrites a saved password either (cx-dwg.8):
/// when its run found sign-ins saved with another password, a toast offers
/// the same Replace as a CSV import. Pressing it saves the held passwords over
/// the saved ones, each into the profile it was imported to; the toast going
/// without it zeroes them and the saved passwords stay.
@MainActor
enum BrowserImportConflictOffer {
    static let toastID = "password-browser-import-conflicts"

    static func offer(_ hold: PasswordConflictHold, windowLookup: @escaping @MainActor () -> NSWindow?) {
        guard hold.count > 0, let window = windowLookup() else { return hold.release() }
        let toast = CmuxToast(id: toastID, message: PasswordCSVStrings.conflicts(hold.count),
                              action: CmuxToast.Action(title: PasswordCSVStrings.replace), duration: .seconds(20))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = {
            Task { @MainActor in
                let message: String
                do {
                    message = PasswordCSVStrings.replaced(try await hold.replace().updated)
                } catch {
                    message = PasswordCSVStrings.replaceFailed
                }
                guard let window = windowLookup() else { return }
                CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: message), in: window)
            }
        }
        handle.onDismiss = { reason in
            if reason != .action { hold.release() }
        }
    }
}
