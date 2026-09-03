import AppKit
import CmuxAuthRuntime
import CmuxFoundation
import CMUXMobileCore
import SwiftUI

/// The macOS page for connecting a mobile device to this Mac.
///
/// Iroh is the account-backed default and never needs a QR code. Tailscale is
/// an explicit compatibility option in the transport chooser.
struct MobilePairingView: View {
    @State private var model = MobilePairingModel()
    @State private var selectedTransport: MobilePairingTransportChoice = .iroh
    @State private var signInModel = AccountSignInModel(
        flow: AppDelegate.shared?.auth?.accountFlow
    )
    /// The manual-entry value that was just copied (the host or the port
    /// string), so only the matching button shows the brief "Copied" flash.
    /// The two values can never collide: one is a host, the other a port.
    @State var copiedValue: String?
    /// Bumped per copy so an older flash's dismissal can't clear a newer one.
    @State var copiedValueGeneration = 0
    #if DEBUG
        /// The design lab can switch the live pairing page between layout treatments.
        @AppStorage(MobilePairingDesignVariant.defaultsKey)
        private var designVariantRaw = MobilePairingDesignVariant.defaultValue.rawValue
    #endif
    /// Reports the scroll content's unconstrained height so the AppKit window
    /// can grow to reveal it while retaining scrolling on shorter displays.
    private let onContentHeightChange: (CGFloat) -> Void

    /// The shared auth coordinator, observed so the view re-runs `refresh()`
    /// when sign-in completes or settles. Captured once; stable post-startup.
    private let coordinator: AuthCoordinator? = AppDelegate.shared?.auth?.coordinator
    private let accountFlow: HostAccountFlow? = AppDelegate.shared?.auth?.accountFlow

    init(onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.onContentHeightChange = onContentHeightChange
    }

    private var designVariant: MobilePairingDesignVariant {
        #if DEBUG
            MobilePairingDesignVariant(rawValue: designVariantRaw)
                ?? MobilePairingDesignVariant.defaultValue
        #else
            .defaultValue
        #endif
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
            if !signingIn {
                Task { await model.refresh() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "mobile.pairing.title", defaultValue: "Pair mobile"))
                .cmuxFont(.title2, weight: .semibold)
            Text(String(
                localized: "mobile.pairing.subtitle",
                defaultValue: "Connect your iPhone to this Mac."
            ))
            .cmuxFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        case let .needsReachableTransport(reachableViaIroh):
            transportContent(.needsReachableTransport(reachableViaIroh: reachableViaIroh))
        case let .failed(message):
            failure(message: message)
        case let .ready(ready):
            transportContent(.ready(ready))
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

    private func transportContent(_ content: MobilePairingTransportView.Content) -> some View {
        MobilePairingTransportView(
            content: content,
            availableIOSAppTargets: model.availableIOSAppTargets,
            selectedIOSAppTarget: model.selectedIOSAppTarget,
            signedInEmail: model.signedInEmail,
            onRefresh: {
                Task { await model.refresh() }
            },
            onSelectIOSAppTarget: { target in
                Task { await model.selectIOSAppTarget(target) }
            },
            copiedValue: copiedValue,
            onCopy: flashCopied,
            selection: $selectedTransport,
            design: designVariant
        )
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
