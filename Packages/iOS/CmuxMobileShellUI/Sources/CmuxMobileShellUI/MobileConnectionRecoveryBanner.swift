import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Surfaces the one connection failure the user must act on: the Mac REJECTED
/// the connection (wrong account / unverifiable token), so retrying cannot
/// help and Sign Out is the only useful action. Transient drops and
/// reconnect attempts deliberately do not render blocking chrome; they ride
/// the status line under the computers picker and the terminal status pill.
/// It can render as a floating pill above terminal content, or as an inline
/// row when the current surface is a list instead of a terminal.
struct MobileConnectionRecoveryBanner: View {
    var connectionRequiresReauth: Bool
    var connectionError: String?
    /// Sign the user out so they can re-authenticate into the account that owns
    /// the Mac.
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
            }
        }
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
}
