import AppKit
import CMUXMobileCore
import SwiftUI

extension MobilePairingView {
    @ViewBuilder
    var connectedContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .cmuxFont(size: 36)
                .foregroundStyle(.green)
            Text(String(localized: "mobile.pairing.connected.title", defaultValue: "iPhone connected"))
                .cmuxFont(.title3, weight: .semibold)
            Text(String(localized: "mobile.pairing.connected.subtitle", defaultValue: "Your terminal workspaces are now syncing to your iPhone. You can close this window."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    func copyButton(label: String, value: String) -> some View {
        Button {
            guard GhosttyApp.terminalPasteboard.writeString(
                value,
                to: .general
            ) else { return }
            flashCopied(value)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                Text(copiedValue == value
                    ? String(localized: "mobile.pairing.manual.copied", defaultValue: "Copied")
                    : label)
            }
            .cmuxFont(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    func flashCopied(_ value: String) {
        copiedValueGeneration &+= 1
        let generation = copiedValueGeneration
        copiedValue = value
        Task { @MainActor in
            try? await ContinuousClock().sleep(for: .seconds(1.6))
            guard copiedValueGeneration == generation else { return }
            copiedValue = nil
        }
    }

    func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// The account-backed mobile connection overview shown before optional
/// Tailscale pairing. Iroh is the normal path: signing in on both devices
/// lets cmux discover the Mac without a QR code.
struct MobileConnectionOverview: View {
    let reachableViaIroh: Bool
    let openTailscalePairing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(String(
                    localized: "mobile.connection.iroh.title",
                    defaultValue: "Iroh connection"
                ))
                .cmuxFont(.title3, weight: .semibold)
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
            }

            Text(String(
                localized: "mobile.pairing.transport.iroh.detail",
                defaultValue: "iPhones signed in to your account find this Mac automatically over Iroh — end-to-end encrypted, direct when possible, through a cmux relay when not. No code needed."
            ))
            .cmuxFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(reachableViaIroh ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(reachableViaIroh
                    ? String(
                        localized: "mobile.pairing.transport.status.ready",
                        defaultValue: "Ready"
                    )
                    : String(
                        localized: "mobile.pairing.transport.status.notRegistered",
                        defaultValue: "Not registered"
                    ))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(String(
                    localized: "mobile.connection.tailscale.prompt",
                    defaultValue: "Need a manual connection?"
                ))
                .cmuxFont(.callout, weight: .medium)

                Button {
                    openTailscalePairing()
                } label: {
                    Label(
                        String(
                            localized: "mobile.connection.tailscale.button",
                            defaultValue: "Open Tailscale Pairing…"
                        ),
                        systemImage: "qrcode"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("MobileOpenTailscalePairingButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
