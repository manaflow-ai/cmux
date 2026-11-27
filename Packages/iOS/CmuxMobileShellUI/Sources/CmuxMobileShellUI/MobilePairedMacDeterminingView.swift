import SwiftUI

/// A neutral, label-free loading state shown for the brief window where the app
/// has not yet determined whether a paired Mac exists.
///
/// This covers an install that predates the persisted paired-Mac hint (the key is
/// absent but a Mac may already be in the store) or a fresh sign-in. It is
/// deliberately label-free: showing "Restoring session…" would mislead a user who
/// turns out to have no session, and showing the add-device sheet would alarm a
/// returning user. Once the async paired-Mac lookup resolves, the root view
/// switches to ``RestoringSessionView`` (a Mac is being reconnected) or the
/// add-device flow (no Mac).
struct MobilePairedMacDeterminingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("MobilePairedMacDetermining")
    }
}
