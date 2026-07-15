import CmuxFoundation
import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import SwiftUI

/// The macOS onboarding window for pairing an iPhone with this Mac.
///
/// Walks the user through same-account authorization and Iroh reachability,
/// then shows an identity-only QR. Tailscale remains an optional compatibility
/// path for released iOS clients and private-only networks.
struct MobilePairingView: View {
    @State private var model = MobilePairingModel()
    /// The manual-entry value that was just copied (the host or the port
    /// string), so only the matching button shows the brief "Copied" flash.
    /// The two values can never collide: one is a host, the other a port.
    @State var copiedValue: String?
    /// Bumped per copy so an older flash's dismissal can't clear a newer one.
    @State var copiedValueGeneration = 0
    /// Defaults to the Iroh identity QR. The user may explicitly reveal the
    /// separately minted released-client Tailscale code when one is available.
    @State private var showsLegacyPairingCode = false

    /// The shared auth coordinator, observed so the view re-runs `refresh()`
    /// when sign-in completes or settles. Captured once; stable post-startup.
    private let coordinator: AuthCoordinator? = AppDelegate.shared?.auth?.coordinator
    private let browserSignIn: HostBrowserSignInFlow? = AppDelegate.shared?.auth?.browserSignIn

    private static let tailscaleDownloadURL = URL(string: "https://tailscale.com/download")!
    /// Where a Mac user goes to get cmux for iPhone while the beta is invite-only.
    static let iphoneAppURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

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
        .onChange(of: browserSignIn?.isPresentingSignIn ?? false) { _, signingIn in
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
            irohRow
            privateNetworkRow
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

    private var irohRow: some View {
        let ready = irohReady
        return requirementRow(
            title: String(
                localized: "mobile.pairing.req.iroh.title",
                defaultValue: "Iroh encrypted transport"
            ),
            subtitle: irohSubtitle(ready: ready)
        ) {
            EmptyView()
        }
    }

    private var privateNetworkRow: some View {
        let reachable = tailscaleReachable
        return requirementRow(
            title: String(
                localized: "mobile.pairing.req.privateNetwork.title",
                defaultValue: "Private network (optional)"
            ),
            subtitle: privateNetworkSubtitle(reachable: reachable)
        ) {
            if reachable == false {
                Link(
                    String(
                        localized: "mobile.pairing.req.tailscale.get",
                        defaultValue: "Get Tailscale"
                    ),
                    destination: Self.tailscaleDownloadURL
                )
                .cmuxFont(.callout)
            }
        }
    }

    /// `true` when the primary QR is Iroh, `false` for compatibility-only, and
    /// `nil` while route registration is unresolved.
    private var irohReady: Bool? {
        switch model.state {
        case let .ready(ready): return ready.reachableViaIroh
        case let .connected(ready): return ready.reachableViaIroh
        case .needsReachableTransport: return false
        default: return nil
        }
    }

    private var tailscaleReachable: Bool? {
        switch model.state {
        case let .ready(ready): return ready.reachableViaTailscale
        case let .connected(ready): return ready.reachableViaTailscale
        case .needsReachableTransport: return false
        default: return nil
        }
    }

    private func irohSubtitle(ready: Bool?) -> String {
        switch ready {
        case .some(true):
            return String(
                localized: "mobile.pairing.req.iroh.ready",
                defaultValue: "Ready. Iroh connects directly when possible and uses a cmux relay when needed."
            )
        case .some(false):
            return String(
                localized: "mobile.pairing.req.iroh.unavailable",
                defaultValue: "Not ready. A Tailscale compatibility route may still be available."
            )
        case .none:
            return String(
                localized: "mobile.pairing.req.iroh.preparing",
                defaultValue: "Registering this Mac's encrypted endpoint."
            )
        }
    }

    private func privateNetworkSubtitle(reachable: Bool?) -> String {
        switch reachable {
        case .some(true):
            return String(
                localized: "mobile.pairing.req.privateNetwork.reachable",
                defaultValue: "Tailscale is available for older-client compatibility and may become a direct Iroh path after admission."
            )
        case .some(false):
            return String(
                localized: "mobile.pairing.req.privateNetwork.missing",
                defaultValue: "Not detected. Iroh pairing does not require Tailscale."
            )
        case .none:
            return String(
                localized: "mobile.pairing.req.privateNetwork.hint",
                defaultValue: "After Iroh admits the phone, Tailscale, another VPN, or the same LAN may become a direct path."
            )
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
        case .needsReachableTransport:
            needsReachableTransportContent
        case let .failed(message):
            failure(message: message)
        case let .ready(ready):
            readyContent(ready)
        case let .connected(ready):
            connectedContent(ready)
        }
    }

    private var needsReachableTransportContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .cmuxFont(size: 28)
                .foregroundStyle(.orange)
            Text(String(
                localized: "mobile.pairing.needsReachableTransport.body",
                defaultValue: "Iroh has not registered this Mac yet, and no Tailscale compatibility route is available. Check the Mac's connection, or enable Tailscale on both devices, then refresh."
            ))
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
        if browserSignIn?.isPresentingSignIn == true {
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
        // Manual entry sits above the QR so Copy IP / Copy Port are reachable
        // without scrolling (they used to sit below the steps, below the fold).
        if ready.reachableViaTailscale {
            manualFallback(ready)
        }

        VStack(alignment: .center, spacing: 14) {
            // The spec 4-module quiet zone (white margin) is baked into the QR
            // bitmap itself, so the code gets no extra white card padding here:
            // the old 12pt-padded white card doubled the visible quiet zone.
            // Width is capped so the manual block, the whole QR, and the
            // waiting indicator all fit the default window without scrolling.
            MobilePairingQRImageView(payload: displayedAttachURL(ready))
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

            pairingCodeModeControls(ready)
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

    private func displayedAttachURL(_ ready: MobilePairingModel.Ready) -> String {
        guard showsLegacyPairingCode,
              let legacyAttachURL = ready.legacyAttachURL else {
            return ready.attachURL
        }
        return legacyAttachURL
    }

    @ViewBuilder
    private func pairingCodeModeControls(_ ready: MobilePairingModel.Ready) -> some View {
        if let _ = ready.legacyAttachURL {
            Text(
                showsLegacyPairingCode
                    ? String(
                        localized: "mobile.pairing.codeMode.legacyDetail",
                        defaultValue: "Compatibility code: the iPhone must be on the same Tailscale network."
                    )
                    : String(
                        localized: "mobile.pairing.codeMode.irohDetail",
                        defaultValue: "Iroh code: encrypted end to end, with direct and relay paths selected automatically."
                    )
            )
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Button(
                showsLegacyPairingCode
                    ? String(
                        localized: "mobile.pairing.codeMode.useIroh",
                        defaultValue: "Use Iroh Code"
                    )
                    : String(
                        localized: "mobile.pairing.codeMode.useLegacy",
                        defaultValue: "Pair an Older iPhone App"
                    )
            ) {
                showsLegacyPairingCode.toggle()
            }
            .buttonStyle(.link)
            .controlSize(.small)
        } else if ready.primaryTransport == .iroh {
            Text(String(
                localized: "mobile.pairing.codeMode.irohDetail",
                defaultValue: "Iroh code: encrypted end to end, with direct and relay paths selected automatically."
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        } else {
            Text(String(
                localized: "mobile.pairing.codeMode.legacyOnlyDetail",
                defaultValue: "Iroh is unavailable, so this code uses the Tailscale compatibility path."
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

}
