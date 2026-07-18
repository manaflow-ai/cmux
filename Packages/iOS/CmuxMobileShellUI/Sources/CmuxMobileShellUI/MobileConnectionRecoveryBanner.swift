import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Top overlay that surfaces mobile-shell connection recovery after a network
/// change (Wi-Fi<->cellular) or drop: a non-blocking "Reconnecting…" pill while
/// automatic recovery runs, and a manual Retry control if it could not restore
/// the connection. Renders nothing while the connection is healthy.
struct MobileConnectionRecoveryBanner: View {
    @Bindable var store: CMUXMobileShellStore
    /// Sign the user out so they can re-authenticate into the account that owns
    /// the Mac. Shown only for the account-mismatch / authorization-failure
    /// state, where Retry cannot help.
    var signOut: (() -> Void)?

    var body: some View {
        Group {
            if store.connectionRequiresReauth {
                authBanner(
                    text: store.connectionError ?? L10n.string(
                        "mobile.recovery.accountMismatch",
                        defaultValue: "This Mac is signed in to a different cmux account. Sign out and sign back in with that account."
                    )
                )
            } else if store.connectionRecoveryFailed {
                banner(
                    text: L10n.string(
                        "mobile.recovery.lost",
                        defaultValue: "Connection lost"
                    ),
                    showsRetry: true,
                    showsSpinner: false
                )
            } else if store.isRecoveringConnection {
                banner(
                    text: L10n.string(
                        "mobile.recovery.reconnecting",
                        defaultValue: "Reconnecting…"
                    ),
                    showsRetry: false,
                    showsSpinner: true
                )
            }
        }
        .animation(.default, value: store.isRecoveringConnection)
        .animation(.default, value: store.connectionRecoveryFailed)
        .animation(.default, value: store.connectionRequiresReauth)
    }

    /// An authorization failure (wrong account / unverifiable token). Retrying
    /// can't fix it, so this surfaces the reason plus a Sign Out action.
    @ViewBuilder
    private func authBanner(text: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.white)
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let signOut {
                Button {
                    signOut()
                } label: {
                    Text(L10n.string("mobile.recovery.switchAccount", defaultValue: "Sign Out & Switch Account"))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.white)
                .foregroundStyle(.black)
                .accessibilityIdentifier("MobileConnectionReauthSignOut")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("MobileConnectionReauthBanner")
    }

    @ViewBuilder
    private func banner(text: String, showsRetry: Bool, showsSpinner: Bool) -> some View {
        HStack(spacing: 10) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if showsRetry {
                Button {
                    store.retryMobileConnection()
                } label: {
                    Text(L10n.string("mobile.recovery.retry", defaultValue: "Retry"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.white)
                .foregroundStyle(.black)
                .accessibilityIdentifier("MobileConnectionRecoveryRetry")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.85), in: Capsule())
        .padding(.top, 8)
        .accessibilityIdentifier("MobileConnectionRecoveryBanner")
    }
}
