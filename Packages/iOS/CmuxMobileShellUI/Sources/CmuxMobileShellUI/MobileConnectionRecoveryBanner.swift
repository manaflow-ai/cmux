import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Surfaces mobile-shell connection recovery after a network change or drop.
/// It can render as a floating pill above terminal content, or as an inline
/// row when the current surface is a list instead of a terminal.
struct MobileConnectionRecoveryBanner: View {
    var connectionRequiresReauth: Bool
    var connectionRecoveryFailed: Bool
    var isRecoveringConnection: Bool
    var connectionError: String?
    var retry: (() -> Void)?
    /// Sign the user out so they can re-authenticate into the account that owns
    /// the Mac. Shown only for the account-mismatch / authorization-failure
    /// state, where Retry cannot help.
    var signOut: (() -> Void)?
    var rendersInline = false

    var body: some View {
        Group {
            if connectionRequiresReauth {
                authBanner(
                    text: connectionError ?? L10n.string(
                        "mobile.recovery.accountMismatch",
                        defaultValue: "This computer is signed in to a different cmux account. Sign out and sign back in with that account."
                    )
                )
            } else if connectionRecoveryFailed {
                banner(
                    title: L10n.string(
                        "mobile.recovery.lost",
                        defaultValue: "Connection lost"
                    ),
                    description: L10n.string(
                        "mobile.recovery.lostDescription",
                        defaultValue: "Retry to restore live terminal updates."
                    ),
                    showsRetry: true,
                    showsSpinner: false
                )
            } else if isRecoveringConnection {
                banner(
                    title: L10n.string(
                        "mobile.recovery.reconnecting",
                        defaultValue: "Reconnecting…"
                    ),
                    description: nil,
                    showsRetry: false,
                    showsSpinner: true
                )
            }
        }
        .animation(.default, value: isRecoveringConnection)
        .animation(.default, value: connectionRecoveryFailed)
        .animation(.default, value: connectionRequiresReauth)
    }

    /// An authorization failure (wrong account / unverifiable token). Retrying
    /// cannot fix it, so this surfaces the reason plus a Sign Out action.
    @ViewBuilder
    private func authBanner(text: String) -> some View {
        if rendersInline {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let signOut {
                    Button {
                        signOut()
                    } label: {
                        Text(L10n.string("mobile.recovery.switchAccount", defaultValue: "Sign Out & Switch Account"))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("MobileConnectionReauthSignOut")
                }
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("MobileConnectionReauthRow")
        } else {
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
    }

    @ViewBuilder
    private func banner(title: String, description: String?, showsRetry: Bool, showsSpinner: Bool) -> some View {
        if rendersInline {
            HStack(spacing: 10) {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if let description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if showsRetry {
                    Button {
                        retry?()
                    } label: {
                        Text(L10n.string("mobile.recovery.retry", defaultValue: "Retry"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("MobileConnectionRecoveryRetry")
                }
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("MobileConnectionRecoveryRow")
        } else {
            HStack(spacing: 10) {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if showsRetry {
                    Button {
                        retry?()
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
}
