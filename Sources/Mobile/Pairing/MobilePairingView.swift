import CmuxFoundation
import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import SwiftUI

/// The macOS window for pairing an iPhone with this Mac.
///
/// The page shows the Tailscale pairing QR and ends in a status row that
/// doubles as the debugging surface (live transport state, manual-entry
/// routes, signed-in account).
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
            Text(String(localized: "mobile.pairing.heading", defaultValue: "Pair your iPhone"))
                .cmuxFont(.title2, weight: .semibold)
            Text(String(
                localized: "mobile.pairing.subheading",
                defaultValue: "Sync your terminal workspaces to your iPhone."
            ))
                .cmuxFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The App Store-badge-styled button for getting cmux on the iPhone.
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
        case .connected:
            connectedContent
        }
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

    // MARK: Ready

    @ViewBuilder
    private func readyContent(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(alignment: .center, spacing: 14) {
            getIPhoneAppBadge
            tailscaleReadyBody(ready)
        }
        .frame(maxWidth: .infinity)

        Divider()

        tailscaleRow(ready)
        manualEntry(ready)

        footer
    }

    @ViewBuilder
    private func tailscaleReadyBody(_ ready: MobilePairingModel.Ready) -> some View {
        // The spec 4-module quiet zone (white margin) is baked into the QR
        // bitmap itself, so the code gets no extra white card padding here:
        // the old 12pt-padded white card doubled the visible quiet zone.
        // Width is capped so the whole QR, the waiting indicator, and the
        // transport details all fit the default window without scrolling.
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
            defaultValue: "In cmux on your iPhone, sign in with the same account, then scan this code."
        ))
        .cmuxFont(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

        if model.availableIOSAppTargets.count > 1 {
            pairingTargetPicker
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
        Button(String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")) {
            Task { await model.refresh() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var pairingTargetPicker: some View {
        HStack(spacing: 6) {
            Text(String(
                localized: "mobile.pairing.targetApp",
                defaultValue: "Open with"
            ))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
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
            .controlSize(.small)
            .fixedSize()
        }
    }

    // MARK: No reachable Tailscale route

    @ViewBuilder
    private var needsReachableTransportContent: some View {
        VStack(alignment: .center, spacing: 14) {
            getIPhoneAppBadge
            tailscaleMissingBody
        }
        .frame(maxWidth: .infinity)

        Divider()

        footer
    }

    @ViewBuilder
    private var tailscaleMissingBody: some View {
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
        refreshButton
    }

    // MARK: Transport status row (debugging surface)

    private func tailscaleRow(_ ready: MobilePairingModel.Ready) -> some View {
        transportRow(
            name: "Tailscale",
            healthy: ready.reachableViaTailscale,
            status: ready.reachableViaTailscale
                ? String(localized: "mobile.pairing.transport.status.connected", defaultValue: "Connected")
                : String(localized: "mobile.pairing.transport.status.notDetected", defaultValue: "Not detected"),
            detail: String(
                localized: "mobile.pairing.transport.tailscale.detail",
                defaultValue: "This code pairs over Tailscale. Both devices must be connected to the same Tailscale network."
            )
        ) {
            if !ready.reachableViaTailscale {
                Link(
                    String(localized: "mobile.pairing.req.tailscale.get", defaultValue: "Get Tailscale"),
                    destination: Self.tailscaleDownloadURL
                )
                .cmuxFont(.caption)
            }
        }
    }

    private func transportRow<Trailing: View>(
        name: String,
        healthy: Bool,
        status: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(healthy ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(name).cmuxFont(.callout, weight: .medium)
                Text(status).cmuxFont(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing()
            }
            Text(detail)
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
        }
    }

    @ViewBuilder
    private func manualEntry(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "mobile.pairing.manual.title", defaultValue: "Can't scan? Add this Mac manually:"))
                .cmuxFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            ForEach(ready.tailscaleLines, id: \.self) { line in
                Text(line).cmuxFont(.caption, design: .monospaced)
                    .textSelection(.enabled).foregroundStyle(.secondary)
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

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if let email = model.signedInEmail {
                Text(String(
                    format: String(localized: "mobile.pairing.signedInAs", defaultValue: "Signed in as %@"),
                    locale: .current,
                    email
                ))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
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
