#if os(iOS)
import CmuxSpinner
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
    /// method can make another account for the same person). The way to this
    /// phone's account sits under step 1's words, in their column, as a link:
    /// flush with the step numbers it read as an orphan label between the
    /// steps (iOS release bar read-back, 2026-11-22, shot 06).
    @ViewBuilder private var otherAccount: some View {
        if let openAccount {
            step(1, signInText) {
                Button(action: openAccount) {
                    HStack(spacing: 3) {
                        Text("Account Settings")
                        Image(systemName: "chevron.forward")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderless)
                .font(theme.type.rowSubtitle.weight(.semibold))
                .foregroundStyle(theme.colors.accent.color)
                .accessibilityIdentifier("connect-mac.account")
            }
        } else {
            step(1, signInText)
        }
    }

    private var signInText: Text {
        if let email, !email.isEmpty {
            return Text("Sign in to cmux on your Mac as \(Text(email).fontWeight(.semibold)).")
        }
        return Text("Sign in to cmux on your Mac with this account.")
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        step(number, text) { EmptyView() }
    }

    /// A numbered step; `accessory` (a link) goes under its words, in their column.
    private func step<Accessory: View>(_ number: Int, _ text: Text,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.colors.label)
                .frame(width: 22, height: 22)
                .background(theme.colors.fill.color, in: .circle)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
            VStack(alignment: .leading, spacing: 6) {
                text
                    .font(theme.type.body)
                    .foregroundStyle(theme.colors.label)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
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
                CmuxSpinner().controlSize(.small)
                Text("Waiting for your Mac…")
            }
        }
        .font(theme.type.rowSubtitle)
        .foregroundStyle(theme.colors.label2)
        .frame(minHeight: 22)
        .contentTransition(.opacity)
        .animation(theme.motion.snappy.animation.unlessReduceMotion, value: onlineMac)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connect-mac.status")
    }
}
#endif
