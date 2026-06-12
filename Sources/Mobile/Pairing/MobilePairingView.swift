import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import SwiftUI

/// The macOS onboarding window for pairing an iPhone with this Mac.
///
/// Walks the user through sign-in and network reachability, then shows either a
/// scannable QR code or manual host/port instructions. Pairing is gated on
/// sign-in because authorization is a Stack same-account check; the user can
/// bring Tailscale, another VPN, or a trusted LAN route.
struct MobilePairingView: View {
    @State private var model = MobilePairingModel()
    /// The manual-entry value that was just copied (the host or the port
    /// string), so only the matching button shows the brief "Copied" flash.
    /// The two values can never collide: one is a host, the other a port.
    @State private var copiedValue: String?
    /// Bumped per copy so an older flash's dismissal can't clear a newer one.
    @State private var copiedValueGeneration = 0

    /// The shared auth coordinator, observed so the view re-runs `refresh()`
    /// when sign-in completes or settles. Captured once; stable post-startup.
    private let coordinator: AuthCoordinator? = AppDelegate.shared?.auth?.coordinator
    private let browserSignIn: HostBrowserSignInFlow? = AppDelegate.shared?.auth?.browserSignIn

    /// Where a Mac user goes to get cmux for iPhone while the beta is invite-only.
    private static let iphoneAppURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                requirements
                Divider()
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.refresh() }
        .onDisappear { model.stopObserving() }
        .onChange(of: coordinator?.isAuthenticated ?? false) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: browserSignIn?.isSigningIn ?? false) { _, signingIn in
            // When the browser flow settles (success or cancel), re-evaluate so a
            // cancelled sign-in returns to the signed-out state instead of spinning.
            if !signingIn { Task { await model.refresh() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "mobile.pairing.window.heading", defaultValue: "Pair your iPhone"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "mobile.pairing.window.subheading", defaultValue: "Scan this code, or enter your Mac's VPN/LAN host and port in the cmux app on your iPhone."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Requirements checklist

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 12) {
            signInRow
            networkRow
        }
    }

    private var signInRow: some View {
        requirementRow(
            title: String(localized: "mobile.pairing.req.signIn.title", defaultValue: "Signed in to cmux"),
            subtitle: model.signedInEmail
                ?? String(localized: "mobile.pairing.req.signIn.subtitle", defaultValue: "Sign in to authorize this Mac for pairing.")
        ) {
            EmptyView()
        }
    }

    private var networkRow: some View {
        let status = networkStatus
        return requirementRow(
            title: String(localized: "mobile.pairing.req.network.title", defaultValue: "Network route"),
            subtitle: networkSubtitle(status: status)
        ) {
            EmptyView()
        }
    }

    private enum NetworkStatus {
        case automatic
        case manual
    }

    private var networkStatus: NetworkStatus? {
        switch model.state {
        case .ready, .connected: return .automatic
        case .manualOnly, .connectedManual: return .manual
        default: return nil
        }
    }

    private func networkSubtitle(status: NetworkStatus?) -> String {
        switch status {
        case .some(.automatic):
            return String(localized: "mobile.pairing.req.network.automatic", defaultValue: "QR ready over Tailscale. Manual VPN/LAN host entry also works.")
        case .some(.manual):
            return String(localized: "mobile.pairing.req.network.manual", defaultValue: "No QR route detected. Enter your own VPN/LAN host and the port below.")
        case .none:
            return String(localized: "mobile.pairing.req.network.hint", defaultValue: "Use Tailscale, your own VPN, or a trusted LAN so the iPhone can reach this Mac.")
        }
    }

    private func requirementRow<Trailing: View>(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    // MARK: Gated content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            centered {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.checking", defaultValue: "Checking…"))
                    .foregroundStyle(.secondary)
            }
        case .signedOut:
            signedOut
        case .preparing:
            centered {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.preparing", defaultValue: "Preparing a pairing code…"))
                    .foregroundStyle(.secondary)
            }
        case let .manualOnly(manual):
            manualOnlyContent(manual)
        case let .failed(message):
            failure(message: message)
        case let .ready(ready):
            readyContent(ready)
        case let .connected(ready):
            connectedContent(ready)
        case let .connectedManual(manual):
            connectedManualContent(manual)
        }
    }

    private func manualOnlyContent(_ manual: MobilePairingModel.ManualOnly) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(String(localized: "mobile.pairing.manualOnly.body", defaultValue: "No QR route was detected. You can still pair over your own VPN or LAN: on your iPhone, tap Add device and enter this Mac's VPN/LAN hostname or IP address with the port below."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                String(
                    format: String(localized: "mobile.pairing.manualOnly.portFormat", defaultValue: "Port: %d"),
                    manual.port
                )
            )
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            copyButton(
                label: String(localized: "mobile.pairing.manual.copyPort", defaultValue: "Copy Port"),
                value: String(manual.port)
            )
            Button(String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var signedOut: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text(String(localized: "mobile.pairing.signIn.prompt", defaultValue: "Sign in with your cmux account to pair your iPhone."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "mobile.pairing.signIn.button", defaultValue: "Sign In")) {
                model.signIn()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func failure(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(String(localized: "mobile.pairing.retry", defaultValue: "Try Again")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    @ViewBuilder
    private func readyContent(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(alignment: .center, spacing: 14) {
            // The QR fills the window width (resize the window for an even
            // bigger code). The spec 4-module quiet zone is baked into the
            // bitmap itself so it scales with the code; the padding and white
            // card here are cosmetic.
            MobilePairingQRImageView(payload: ready.attachURL)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
                .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.waiting", defaultValue: "Waiting for your iPhone…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)

        steps

        manualFallback(ready)

        HStack {
            Spacer()
            Button(String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func connectedContent(_: MobilePairingModel.Ready) -> some View {
        connectedContent()
    }

    private func connectedManualContent(_: MobilePairingModel.ManualOnly) -> some View {
        connectedContent()
    }

    private func connectedContent() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text(String(localized: "mobile.pairing.connected.title", defaultValue: "iPhone connected"))
                .font(.title3.weight(.semibold))
            Text(String(localized: "mobile.pairing.connected.subtitle", defaultValue: "Your terminal workspaces are now syncing to your iPhone. You can close this window."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, String(localized: "mobile.pairing.step.install", defaultValue: "Install cmux on your iPhone and open it."))
            HStack(spacing: 4) {
                Spacer(minLength: 30)
                Text(String(localized: "mobile.pairing.getApp.prompt", defaultValue: "Don't have it yet?"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    String(localized: "mobile.pairing.getApp.link", defaultValue: "Get cmux for iPhone"),
                    destination: Self.iphoneAppURL
                )
                .font(.caption)
                Spacer(minLength: 0)
            }
            step(2, String(localized: "mobile.pairing.step.signIn", defaultValue: "Sign in with the same account you use on this Mac."))
            step(3, String(localized: "mobile.pairing.step.scan", defaultValue: "Tap Add device, then Scan QR Code, and point the camera at the code above."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func manualFallback(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "mobile.pairing.manual.title", defaultValue: "Can't scan? Add this Mac manually:"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(ready.tailscaleLines, id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            if let entry = ready.manualEntry {
                HStack(spacing: 8) {
                    copyButton(
                        label: String(localized: "mobile.pairing.manual.copyIP", defaultValue: "Copy IP"),
                        value: entry.host
                    )
                    copyButton(
                        label: String(localized: "mobile.pairing.manual.copyPort", defaultValue: "Copy Port"),
                        value: String(entry.port)
                    )
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// One of the two manual-entry copy controls. Copies `value` to the
    /// general pasteboard and briefly swaps its label to a "Copied" check.
    private func copyButton(label: String, value: String) -> some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            flashCopied(value)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                Text(
                    copiedValue == value
                        ? String(localized: "mobile.pairing.manual.copied", defaultValue: "Copied")
                        : label
                )
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func flashCopied(_ value: String) {
        copiedValueGeneration &+= 1
        let generation = copiedValueGeneration
        copiedValue = value
        Task { @MainActor in
            // Bounded, intended auto-dismiss for the "Copied" flash (same
            // pattern as MarkdownPanelView's copy confirmation); a newer copy
            // supersedes this one via the generation guard.
            try? await ContinuousClock().sleep(for: .seconds(1.6))
            guard copiedValueGeneration == generation else { return }
            copiedValue = nil
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, minHeight: 200)
    }
}
