import CmuxFoundation
import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import SwiftUI

/// The macOS onboarding window for pairing an iPhone with this Mac.
///
/// Walks the user through the two requirements (signed in to cmux, Tailscale
/// reachable) and then shows a scannable QR code with step-by-step
/// instructions. Pairing is gated on sign-in because authorization is a Stack
/// same-account check; Tailscale is what gives the iPhone a route to this Mac.
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

    private static let tailscaleDownloadURL = URL(string: "https://tailscale.com/download")!
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
                .cmuxFont(.title2, weight: .semibold)
            Text(String(localized: "mobile.pairing.window.subheading", defaultValue: "Scan this code with the cmux app on your iPhone to sync your terminal workspaces."))
                .cmuxFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Requirements checklist

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 12) {
            signInRow
            tailscaleRow
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

    private var tailscaleRow: some View {
        let reachable = tailscaleReachable
        return requirementRow(
            title: String(localized: "mobile.pairing.req.tailscale.title", defaultValue: "Tailscale"),
            subtitle: tailscaleSubtitle(reachable: reachable)
        ) {
            if reachable != true {
                Link(
                    String(localized: "mobile.pairing.req.tailscale.get", defaultValue: "Get Tailscale"),
                    destination: Self.tailscaleDownloadURL
                )
                .cmuxFont(.callout)
            }
        }
    }

    /// `true` reachable, `false` not detected, `nil` not yet known.
    private var tailscaleReachable: Bool? {
        switch model.state {
        case let .ready(ready): return ready.reachableViaTailscale
        case let .connected(ready): return ready.reachableViaTailscale
        case .needsTailscale: return false
        default: return nil
        }
    }

    private func tailscaleSubtitle(reachable: Bool?) -> String {
        switch reachable {
        case .some(true):
            return String(localized: "mobile.pairing.req.tailscale.reachable", defaultValue: "Reachable over Tailscale.")
        case .some(false):
            return String(localized: "mobile.pairing.req.tailscale.missing", defaultValue: "Not detected. Install Tailscale on this Mac and your iPhone, signed in to the same account.")
        case .none:
            return String(localized: "mobile.pairing.req.tailscale.hint", defaultValue: "Your Mac and iPhone both need Tailscale to connect over the internet.")
        }
    }

    private func requirementRow<Trailing: View>(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).cmuxFont(.callout, weight: .medium)
                Text(subtitle)
                    .cmuxFont(.caption)
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
            loadingContent
        case .signedOut:
            signedOut
        case .preparing:
            centered {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.preparing", defaultValue: "Preparing a pairing code…"))
                    .foregroundStyle(.secondary)
            }
        case .needsTailscale:
            needsTailscaleContent
        case let .failed(message):
            failure(message: message)
        case let .ready(ready):
            readyContent(ready)
        case let .connected(ready):
            connectedContent(ready)
        }
    }

    private var needsTailscaleContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .cmuxFont(size: 28)
                .foregroundStyle(.orange)
            Text(String(localized: "mobile.pairing.needsTailscale.body", defaultValue: "This Mac has no Tailscale address, so your iPhone can't reach it. Install Tailscale on this Mac and your iPhone (same account), then refresh."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(
                String(localized: "mobile.pairing.req.tailscale.get", defaultValue: "Get Tailscale"),
                destination: Self.tailscaleDownloadURL
            )
            .buttonStyle(.borderedProminent)
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
                .cmuxFont(size: 28)
                .foregroundStyle(.tint)
            Text(String(localized: "mobile.pairing.signIn.prompt", defaultValue: "Sign in with your cmux account to pair your iPhone."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let lastFailure = browserSignIn?.lastFailure?.errorDescription, !lastFailure.isEmpty {
                Text(lastFailure)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(String(localized: "mobile.pairing.signIn.button", defaultValue: "Sign In")) {
                model.signIn()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    @ViewBuilder
    private var loadingContent: some View {
        if browserSignIn?.isSigningIn == true {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "mobile.pairing.signIn.connecting", defaultValue: "Connecting…"))
                        .foregroundStyle(.secondary)
                }
                if browserSignIn?.signInIsSlow == true {
                    slowSignInFallback
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            centered {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.checking", defaultValue: "Checking…"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var slowSignInFallback: some View {
        VStack(spacing: 8) {
            Text(String(
                localized: "mobile.pairing.signIn.slowHint",
                defaultValue: "The system sign-in window may stop responding. If nothing happens, open sign-in in your default browser instead."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                guard let url = browserSignIn?.activeAttemptSignInURL else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Text(String(
                    localized: "mobile.pairing.signIn.openInBrowser",
                    defaultValue: "Open in Browser"
                ))
            }
            .controlSize(.small)
        }
        .frame(maxWidth: 360)
    }

    private func failure(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .cmuxFont(size: 28)
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
        // Manual entry sits above the QR so Copy Address is reachable
        // without scrolling (it used to sit below the steps, below the fold).
        if ready.reachableViaTailscale {
            manualFallback(ready)
        }

        VStack(alignment: .center, spacing: 14) {
            // The spec 4-module quiet zone (white margin) is baked into the QR
            // bitmap itself, so the code gets no extra white card padding here:
            // the old 12pt-padded white card doubled the visible quiet zone.
            // Width is capped so the manual block, the whole QR, and the
            // waiting indicator all fit the default window without scrolling.
            MobilePairingQRImageView(payload: ready.attachURL)
                .frame(maxWidth: 380)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.waiting", defaultValue: "Waiting for your iPhone…"))
                    .cmuxFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)

        steps

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
    private func connectedContent(_ ready: MobilePairingModel.Ready) -> some View {
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

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, String(localized: "mobile.pairing.step.install", defaultValue: "Install cmux on your iPhone and open it."))
            HStack(spacing: 4) {
                Spacer(minLength: 30)
                Text(String(localized: "mobile.pairing.getApp.prompt", defaultValue: "Don't have it yet?"))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    String(localized: "mobile.pairing.getApp.link", defaultValue: "Get cmux for iPhone"),
                    destination: Self.iphoneAppURL
                )
                .cmuxFont(.caption)
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
                .cmuxFont(.caption, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .cmuxFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func manualFallback(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "mobile.pairing.manual.title", defaultValue: "Can't scan? Add this Mac manually:"))
                .cmuxFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            ForEach(ready.tailscaleLines, id: \.self) { line in
                Text(line)
                    .cmuxFont(.caption, design: .monospaced)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            if let entry = ready.manualEntry {
                copyButton(
                    label: String(localized: "mobile.pairing.manual.copyAddress", defaultValue: "Copy Address"),
                    value: entry.displayString
                )
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The manual-entry copy control. Copies `value` to the general
    /// pasteboard and briefly swaps its label to a "Copied" check.
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
            .cmuxFont(.caption)
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
