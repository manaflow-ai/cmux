#if os(iOS)
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// How a Mac reaches this iPhone: there is no pairing code. A Mac signed in
/// to the same account, with iPhone connections allowed, appears by itself
/// in whichever team or personal space it uses (PROTOCOL.md
/// `GET /v1/me/macs`). Two numbered steps and a live status line that flips
/// when the Mac shows up. Used by the Workspaces empty state and the
/// first-run setup. The Mac's switch lives in its Settings → Mobile.
public struct ConnectMacSteps: View {
    let email: String?
    /// The first online Mac, once one appears.
    let onlineMac: String?
    /// The team the Mac was found in, when the account has several.
    let teamName: String?
    /// The account has no Mac in any space: the Mac may use another account.
    let noMacsForAccount: Bool
    /// Opens Settings → Account (the shell only).
    let openAccount: (() -> Void)?

    public init(email: String?, onlineMac: String?, teamName: String? = nil,
                noMacsForAccount: Bool = false, openAccount: (() -> Void)? = nil) {
        self.email = email
        self.onlineMac = onlineMac
        self.teamName = teamName
        self.noMacsForAccount = noMacsForAccount
        self.openAccount = openAccount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if onlineMac == nil, noMacsForAccount {
                otherAccount
            } else {
                step(1, signInText)
            }
            // A Mac with connections disabled has not registered with the account either.
            step(2, Text("In cmux on your Mac, turn on \(Text("Settings → Mobile → Allow iPhone Connections").fontWeight(.semibold))."))
            status
                .padding(.top, 6)
        }
        .frame(maxWidth: 340, alignment: .leading)
    }

    /// Said plainly when no Mac is signed in to this account anywhere: the
    /// usual cause is a Mac signed in with another account (another sign-in
    /// method can make another account for the same person).
    private var otherAccount: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, signInText)
            if let openAccount {
                Button("Account Settings", action: openAccount)
                    .font(theme.type.rowSubtitle.weight(.semibold))
                    .foregroundStyle(theme.colors.label)
                    .accessibilityIdentifier("connect-mac.account")
            }
        }
    }

    private var signInText: Text {
        if let email, !email.isEmpty {
            return Text("Sign in to cmux on your Mac as \(Text(email).fontWeight(.semibold)).")
        }
        return Text("Sign in to cmux on your Mac with this account.")
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.colors.label)
                .frame(width: 22, height: 22)
                .background(theme.colors.fill.color, in: .circle)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
            text
                .font(theme.type.body)
                .foregroundStyle(theme.colors.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if let onlineMac {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.colors.success.color)
                if let teamName {
                    Text("\(onlineMac) is online in \(teamName)")
                } else {
                    Text("\(onlineMac) is online")
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for your Mac…")
            }
        }
        .font(theme.type.rowSubtitle)
        .foregroundStyle(theme.colors.label2)
        .frame(minHeight: 22)
        .contentTransition(.opacity)
        .animation(theme.motion.snappy.animation, value: onlineMac)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connect-mac.status")
    }
}
#endif
