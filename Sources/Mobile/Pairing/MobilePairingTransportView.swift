import AppKit
import CMUXMobileCore
import CmuxFoundation
import SwiftUI

/// Renders the transport chooser and its two pairing presentations.
///
/// Iroh is the account-backed default. Tailscale remains an explicit choice for
/// QR or manually-entered host pairing, so the primary Mobile Connection page
/// stays useful without making a QR code the first thing a user sees.
struct MobilePairingTransportView: View {
    /// The waiting content to render beneath the transport chooser.
    enum Content: Equatable {
        case ready(MobilePairingModel.Ready)
        case needsReachableTransport(reachableViaIroh: Bool)

        var reachableViaIroh: Bool {
            switch self {
            case let .ready(ready):
                ready.reachableViaIroh
            case let .needsReachableTransport(reachableViaIroh):
                reachableViaIroh
            }
        }

        var ready: MobilePairingModel.Ready? {
            guard case let .ready(ready) = self else { return nil }
            return ready
        }
    }

    private enum TransportChoice: Hashable {
        case iroh
        case tailscale
    }

    let content: Content
    let availableIOSAppTargets: [MobileIOSAppTarget]
    let selectedIOSAppTarget: MobileIOSAppTarget
    let signedInEmail: String?
    let onRefresh: () -> Void
    let onSelectIOSAppTarget: (MobileIOSAppTarget) -> Void
    let copiedValue: String?
    let onCopy: (String) -> Void

    @State private var chosenTransport: TransportChoice?

    private static let tailscaleDownloadURL = URL(string: "https://tailscale.com/download")!
    private static let iphoneAppURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

    var body: some View {
        let transport = chosenTransport ?? .iroh

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .center, spacing: 14) {
                transportPicker
                getIPhoneAppBadge
                switch transport {
                case .iroh:
                    irohBody(waiting: content.reachableViaIroh)
                case .tailscale:
                    if let ready = content.ready, ready.reachableViaTailscale {
                        tailscaleReadyBody(ready)
                    } else {
                        tailscaleMissingBody
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            switch transport {
            case .iroh:
                irohRow(reachableViaIroh: content.reachableViaIroh)
            case .tailscale:
                if let ready = content.ready, ready.reachableViaTailscale {
                    tailscaleRow(ready)
                    manualEntry(ready)
                }
            }

            if let signedInEmail {
                HStack {
                    Text(String(
                        format: String(localized: "mobile.pairing.signedInAs", defaultValue: "Signed in as %@"),
                        locale: .current,
                        signedInEmail
                    ))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .onAppear { chosenTransport = nil }
    }

    private var transportPicker: some View {
        Picker(
            String(localized: "mobile.pairing.transportPicker", defaultValue: "Connection"),
            selection: Binding(
                get: { chosenTransport ?? .iroh },
                set: { chosenTransport = $0 }
            )
        ) {
            Text(verbatim: "Iroh").tag(TransportChoice.iroh)
            Text(verbatim: "Tailscale").tag(TransportChoice.tailscale)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
        .accessibilityIdentifier("MobileConnectionTransportPicker")
    }

    private var getIPhoneAppBadge: some View {
        Link(destination: Self.iphoneAppURL) {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .cmuxFont(size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(
                        localized: "mobile.pairing.getApp.badge.caption",
                        defaultValue: "Download cmux for"
                    ))
                    .cmuxFont(.caption2)
                    Text(String(
                        localized: "mobile.pairing.getApp.badge.platform",
                        defaultValue: "iPhone"
                    ))
                    .cmuxFont(.title3, weight: .semibold)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(
            localized: "mobile.pairing.getApp.link",
            defaultValue: "Get cmux for iPhone"
        ))
    }

    @ViewBuilder
    private func irohBody(waiting: Bool) -> some View {
        Text(String(
            localized: "mobile.pairing.irohInstruction",
            defaultValue: "Install cmux on your iPhone and sign in with the same account. It connects automatically — no code needed."
        ))
        .cmuxFont(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)

        if waiting {
            waitingIndicator
        }
        if availableIOSAppTargets.count > 1 {
            pairingTargetPicker
        }
    }

    @ViewBuilder
    private func tailscaleReadyBody(_ ready: MobilePairingModel.Ready) -> some View {
        MobilePairingQRImageView(payload: ready.attachURL)
            .frame(maxWidth: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2))
            )

        HStack(spacing: 10) {
            waitingIndicator
            refreshButton
        }

        Text(String(
            localized: "mobile.pairing.scanInstruction",
            defaultValue: "In cmux on your iPhone, sign in with the same account, choose Tailscale, then scan this code."
        ))
        .cmuxFont(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

        if availableIOSAppTargets.count > 1 {
            pairingTargetPicker
        }
    }

    private var tailscaleMissingBody: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "network.slash")
                .cmuxFont(size: 28)
                .foregroundStyle(.orange)
            Text(String(
                localized: "mobile.pairing.req.tailscale.missing",
                defaultValue: "Tailscale is not connected on this Mac. Install it on both devices and connect both to the same Tailscale network."
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Link(
                String(localized: "mobile.pairing.req.tailscale.get", defaultValue: "Get Tailscale"),
                destination: Self.tailscaleDownloadURL
            )
            .buttonStyle(.borderedProminent)
            refreshButton
        }
    }

    private var waitingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(String(localized: "mobile.pairing.waiting", defaultValue: "Waiting for your iPhone…"))
                .cmuxFont(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button(String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code"), action: onRefresh)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private var pairingTargetPicker: some View {
        HStack(spacing: 6) {
            Text(String(localized: "mobile.pairing.targetApp", defaultValue: "Open with"))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
            Picker(
                String(localized: "mobile.pairing.targetApp", defaultValue: "Open with"),
                selection: Binding(
                    get: { selectedIOSAppTarget },
                    set: onSelectIOSAppTarget
                )
            ) {
                ForEach(availableIOSAppTargets) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func irohRow(reachableViaIroh: Bool) -> some View {
        transportRow(
            name: "Iroh",
            healthy: reachableViaIroh,
            status: reachableViaIroh
                ? String(localized: "mobile.pairing.transport.status.ready", defaultValue: "Ready")
                : String(localized: "mobile.pairing.transport.status.notRegistered", defaultValue: "Not registered"),
            detail: String(
                localized: "mobile.pairing.transport.iroh.detail",
                defaultValue: "iPhones signed in to your account find this Mac automatically over Iroh — end-to-end encrypted, direct when possible, through a cmux relay when not. No code needed."
            )
        )
    }

    private func tailscaleRow(_ ready: MobilePairingModel.Ready) -> some View {
        transportRow(
            name: "Tailscale",
            healthy: ready.reachableViaTailscale,
            status: ready.reachableViaTailscale
                ? String(localized: "mobile.pairing.transport.status.connected", defaultValue: "Connected")
                : String(localized: "mobile.pairing.transport.status.notDetected", defaultValue: "Not detected"),
            detail: String(
                localized: "mobile.pairing.transport.tailscale.detail",
                defaultValue: "This code pairs over Tailscale instead. Both devices must be connected to the same Tailscale network."
            )
        )
    }

    private func transportRow(name: String, healthy: Bool, status: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(healthy ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(verbatim: name).cmuxFont(.callout, weight: .medium)
                Text(status).cmuxFont(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            Text(detail)
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
        }
    }

    private func manualEntry(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                localized: "mobile.pairing.manual.title",
                defaultValue: "Can't scan? Add this Mac manually:"
            ))
            .cmuxFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            ForEach(ready.tailscaleLines, id: \.self) { line in
                Text(line)
                    .cmuxFont(.caption, design: .monospaced)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            if let entry = ready.manualEntry {
                HStack(spacing: 8) {
                    copyButton(label: String(localized: "mobile.pairing.manual.copyIP", defaultValue: "Copy IP"), value: entry.host)
                    copyButton(label: String(localized: "mobile.pairing.manual.copyPort", defaultValue: "Copy Port"), value: String(entry.port))
                }
                .padding(.top, 2)
            }
        }
        .padding(.leading, 12)
    }

    private func copyButton(label: String, value: String) -> some View {
        Button {
            guard GhosttyApp.terminalPasteboard.writeString(value, to: .general) else { return }
            onCopy(value)
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
}
