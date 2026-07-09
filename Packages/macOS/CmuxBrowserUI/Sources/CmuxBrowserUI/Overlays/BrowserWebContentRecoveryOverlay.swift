public import SwiftUI

/// The browser panel's web-content recovery overlay: a dimmed chrome backdrop
/// with a centered reload button, shown when the panel's web content has
/// terminated and can be recovered.
///
/// Renders from a ``BrowserWebContentRecoverySnapshot`` and invokes
/// ``BrowserWebContentRecoveryActions``. The app-side forwarder builds the
/// snapshot (localized strings + chrome backdrop) and wires `onReload` to the
/// panel's recovery path.
public struct BrowserWebContentRecoveryOverlay: View {
    private let snapshot: BrowserWebContentRecoverySnapshot
    private let actions: BrowserWebContentRecoveryActions

    /// Creates the recovery overlay from a snapshot and its actions.
    public init(
        snapshot: BrowserWebContentRecoverySnapshot,
        actions: BrowserWebContentRecoveryActions
    ) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        ZStack {
            snapshot.backgroundColor
                .opacity(0.92)
            Button(action: actions.onReload) {
                Label(
                    snapshot.reloadLabel,
                    systemImage: snapshot.reloadSystemImage
                )
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .safeHelp(snapshot.reloadHelp)
            .accessibilityIdentifier(snapshot.accessibilityIdentifier)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
