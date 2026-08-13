import CmuxFoundation
import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import SwiftUI

/// The macOS Tailscale QR flow for pairing an iPhone with this Mac.
///
/// Automatic Iroh discovery needs no QR. This window walks the user through
/// same-account authorization and shows the Tailscale code used when the
/// iPhone's connection method is explicitly set to Tailscale.
struct MobilePairingView: View {
    @State private var model = MobilePairingModel()
    @State private var signInModel = AccountSignInModel(
        flow: AppDelegate.shared?.auth?.accountFlow
    )
    /// The manual-entry value that was just copied (the host or the port
    /// string), so only the matching button shows the brief "Copied" flash.
    /// The two values can never collide: one is a host, the other a port.
    @State var copiedValue: String?
    /// Bumped per copy so an older flash's dismissal can't clear a newer one.
    @State var copiedValueGeneration = 0
    /// Reports the scroll content's unconstrained height so the AppKit window
    /// can grow to reveal it while retaining scrolling on shorter displays.
    private let onContentHeightChange: (CGFloat) -> Void

    /// The shared auth coordinator, observed so the view re-runs `refresh()`
    /// when sign-in completes or settles. Captured once; stable post-startup.
    private let coordinator: AuthCoordinator? = AppDelegate.shared?.auth?.coordinator
    private let accountFlow: HostAccountFlow? = AppDelegate.shared?.auth?.accountFlow

    private static let tailscaleDownloadURL = URL(string: "https://tailscale.com/download")!
    /// Where a Mac user goes to get cmux for iPhone while the beta is invite-only.
    static let iphoneAppURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

    init(onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.onContentHeightChange = onContentHeightChange
    }

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
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: MobilePairingContentHeightPreferenceKey.self,
                        value: MobilePairingContentMeasurement(
                            height: geometry.size.height,
                            state: model.state
                        )
                    )
                }
            }
        }
        .onPreferenceChange(MobilePairingContentHeightPreferenceKey.self) { measurement in
            onContentHeightChange(measurement.height)
        }
        .task { await model.refresh() }
        .onDisappear { model.stopObserving() }
        .onChange(of: coordinator?.isAuthenticated ?? false) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: accountFlow?.isPresentingSignIn ?? false) { _, signingIn in
            // When the browser flow settles (success or cancel), re-evaluate so a
            // cancelled sign-in returns to the signed-out state instead of spinning.
            if !signingIn { Task { await model.refresh() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "mobile.pairing.window.heading", defaultValue: "Pair your iPhone with Tailscale"))
                .cmuxFont(.title2, weight: .semibold)
            Text(String(
                localized: "mobile.pairing.window.subheading",
                defaultValue: "iPhones on your cmux account connect automatically. Use this code only for Tailscale."
            ))
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
            title: String(
                localized: "mobile.pairing.req.tailscale.title",
                defaultValue: "Tailscale"
            ),
            subtitle: tailscaleSubtitle(reachable: reachable)
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

    private var tailscaleReachable: Bool? {
        switch model.state {
        case let .ready(ready): return ready.reachableViaTailscale
        case let .connected(ready): return ready.reachableViaTailscale
        case .needsReachableTransport: return false
        default: return nil
        }
    }

    private func tailscaleSubtitle(reachable: Bool?) -> String {
        switch reachable {
        case .some(true):
            return String(
                localized: "mobile.pairing.req.tailscale.reachable",
                defaultValue: """
                Tailscale is connected on this Mac. It must also be installed and connected on your iPhone. \
                Both devices must be connected to the same Tailscale network.
                """
            )
        case .some(false):
            return String(
                localized: "mobile.pairing.req.tailscale.missing",
                defaultValue: """
                Tailscale is not connected on this Mac. Install it on both devices \
                and connect both to the same Tailscale network.
                """
            )
        case .none:
            return String(
                localized: "mobile.pairing.req.tailscale.hint",
                defaultValue: """
                Tailscale must be installed and connected on both this Mac and your iPhone. \
                Both devices must be connected to the same Tailscale network.
                """
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
            AccountSignInView(model: signInModel, automaticallyStartsSignIn: false)
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
                localized: "mobile.pairing.req.tailscale.missing",
                defaultValue: """
                Tailscale is not connected on this Mac. Install it on both devices \
                and connect both to the same Tailscale network.
                """
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

    @ViewBuilder
    private var loadingContent: some View {
        if accountFlow?.isPresentingSignIn == true {
            AccountSignInView(model: signInModel, automaticallyStartsSignIn: false)
        } else {
            centered {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.checking", defaultValue: "Checking…"))
                    .foregroundStyle(.secondary)
            }
        }
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
        if model.availableIOSAppTargets.count > 1 {
            pairingTargetPicker
        }

        // Manual entry sits above the QR so Copy IP / Copy Port are reachable
        // without scrolling (they used to sit below the steps, below the fold).
        manualFallback(ready)

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

            Text(String(
                localized: "mobile.pairing.codeMode.tailscaleDetail",
                defaultValue: """
                Tailscale pairing code. Keep Tailscale connected on both devices. \
                Both devices must be connected to the same Tailscale network.
                """
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
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

    private var pairingTargetPicker: some View {
        HStack {
            Text(String(
                localized: "mobile.pairing.targetApp",
                defaultValue: "Open with"
            ))
                .cmuxFont(.callout, weight: .medium)
            Spacer()
            Picker(
                String(
                    localized: "mobile.pairing.targetApp",
                    defaultValue: "Open with"
                ),
                selection: Binding(
                    get: { model.selectedIOSAppTarget },
                    set: { target in
                        Task { await model.selectIOSAppTarget(target) }
                    }
                )
            ) {
                ForEach(model.availableIOSAppTargets) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

}

private struct MobilePairingContentMeasurement: Equatable {
    let height: CGFloat
    let state: MobilePairingModel.State
}

private struct MobilePairingContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue = MobilePairingContentMeasurement(
        height: 0,
        state: .loading
    )

    static func reduce(
        value: inout MobilePairingContentMeasurement,
        nextValue: () -> MobilePairingContentMeasurement
    ) {
        let next = nextValue()
        if next.height >= value.height {
            value = next
        }
    }
}
