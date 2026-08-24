#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// First-run flow: welcome pitch, Mac connection, push-notification offer.
/// Sign-in happens between welcome and connect (the root swaps to sign-in
/// whenever a post-welcome milestone lacks authentication), and every step is
/// skippable: welcome's Skip leaves the whole flow, connect's Skip defers
/// setup to the shell, and the push stage carries its own "Not Now".
struct OnboardingFlowView: View {
    let context: OnboardingContext
    let connectionPhase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void
    let onReachedConnection: () -> Void
    let onReachedPush: () -> Void
    let onSkipFlow: () -> Void
    let onRetryConnection: () -> Void
    let onStartTailscalePairing: () -> Void
    let onEnablePush: () async -> Bool
    let onDeclinePush: () -> Void
    let onComplete: () -> Void

    @State private var stage: OnboardingStage
    @State private var didReachConnection = false
    @State private var didReachPush = false
    @State private var didRecordStart = false
    @State private var isEnablingPush = false
    @Environment(\.analytics) private var analytics
    @Environment(\.mobileDiagnosticLog) private var diagnosticLog

    init(
        initialStage: OnboardingStage,
        context: OnboardingContext,
        connectionPhase: OnboardingConnectionPhase,
        connectionMethod: MobileConnectionMethod = .automatic,
        onSelectConnectionMethod: @escaping (MobileConnectionMethod) -> Void = { _ in },
        onReachedConnection: @escaping () -> Void,
        onReachedPush: @escaping () -> Void,
        onSkipFlow: @escaping () -> Void,
        onRetryConnection: @escaping () -> Void,
        onStartTailscalePairing: @escaping () -> Void,
        onEnablePush: @escaping () async -> Bool,
        onDeclinePush: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.context = context
        self.connectionPhase = connectionPhase
        self.connectionMethod = connectionMethod
        self.onSelectConnectionMethod = onSelectConnectionMethod
        self.onReachedConnection = onReachedConnection
        self.onReachedPush = onReachedPush
        self.onSkipFlow = onSkipFlow
        self.onRetryConnection = onRetryConnection
        self.onStartTailscalePairing = onStartTailscalePairing
        self.onEnablePush = onEnablePush
        self.onDeclinePush = onDeclinePush
        self.onComplete = onComplete
        _stage = State(initialValue: initialStage)
    }

    var body: some View {
        OnboardingSceneContainer(
            stage: stage,
            chrome: chrome,
            onBack: handleBack,
            onSkip: handleSkip,
            onPrimary: handlePrimary,
            onSecondary: handleSecondary,
            pageContent: OnboardingPageViewport(
                stage: stage,
                onNavigate: { navigate(to: $0) }
            ) { pageStage in
                page(for: pageStage)
            }
        )
        .interactiveDismissDisabled()
        .onAppear {
            if !didRecordStart {
                didRecordStart = true
                diagnosticLog?.recordAppEvent(.onboardingStarted)
            }
            captureSceneViewed()
            recordStageArrival()
        }
        .onChange(of: stage) { _, _ in
            captureSceneViewed()
            recordStageArrival()
        }
    }

    private var chrome: OnboardingSceneChrome {
        OnboardingSceneChrome(
            stage: stage,
            connectionPhase: connectionPhase,
            connectionMethod: connectionMethod
        )
    }

    @ViewBuilder
    private func page(for pageStage: OnboardingStage) -> some View {
        switch pageStage {
        case .welcome:
            OnboardingWelcomeView()
        case .connect:
            OnboardingConnectionView(
                phase: connectionPhase,
                connectionMethod: connectionMethod,
                onSelectConnectionMethod: selectConnectionMethod,
                onStartTailscalePairing: startTailscalePairing
            )
        case .push:
            OnboardingPushView()
        }
    }

    private func handleBack() {
        switch stage {
        case .welcome:
            break
        case .connect:
            navigate(to: .welcome)
        case .push:
            navigate(to: .connect)
        }
    }

    /// Welcome's Skip leaves the whole flow; connect's Skip defers Mac setup
    /// and moves on to the push offer. The push stage hides the header Skip in
    /// favor of its explicit "Not Now" secondary.
    private func handleSkip() {
        diagnosticLog?.recordAppEvent(.onboardingSkipped)
        analytics.capture("ios_onboarding_skipped", eventProperties)
        switch stage {
        case .welcome:
            onSkipFlow()
        case .connect:
            navigate(to: .push)
        case .push:
            finish()
        }
    }

    private func handlePrimary() {
        switch stage {
        case .welcome:
            navigate(to: .connect)
        case .connect:
            handleConnectPrimary()
        case .push:
            enablePushAndFinish()
        }
    }

    private func handleConnectPrimary() {
        switch connectionPhase {
        case .idle, .fallback:
            if connectionMethod == .tailscale {
                startTailscalePairing()
            } else {
                diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
                analytics.capture("ios_onboarding_connection_retried", eventProperties)
                onRetryConnection()
            }
        case .searching:
            break
        case .ready:
            navigate(to: .push)
        }
    }

    private func handleSecondary() {
        switch stage {
        case .welcome:
            break
        case .connect:
            guard connectionPhase == .fallback else { return }
            if connectionMethod == .tailscale {
                diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
                analytics.capture("ios_onboarding_connection_retried", eventProperties)
                onRetryConnection()
            } else {
                startTailscalePairing()
            }
        case .push:
            analytics.capture("ios_onboarding_push_declined", eventProperties)
            onDeclinePush()
            finish()
        }
    }

    private func enablePushAndFinish() {
        guard !isEnablingPush else { return }
        isEnablingPush = true
        analytics.capture("ios_onboarding_push_accepted", eventProperties)
        Task {
            defer { isEnablingPush = false }
            _ = await onEnablePush()
            finish()
        }
    }

    private func finish() {
        diagnosticLog?.recordAppEvent(.onboardingCompleted)
        analytics.capture("ios_onboarding_completed", eventProperties)
        onComplete()
    }

    private func recordStageArrival() {
        switch stage {
        case .welcome:
            break
        case .connect:
            guard !didReachConnection else { return }
            didReachConnection = true
            onReachedConnection()
        case .push:
            guard !didReachPush else { return }
            didReachPush = true
            onReachedPush()
        }
    }

    private func navigate(to destination: OnboardingStage) {
        guard destination != stage else { return }
        stage = destination
    }

    private func selectConnectionMethod(_ method: MobileConnectionMethod) {
        guard method != connectionMethod else { return }
        diagnosticLog?.recordAppEvent(.onboardingConnectionMethodChanged)
        var properties = eventProperties
        properties["connection_method"] = .string(method.rawValue)
        analytics.capture("ios_onboarding_connection_method_selected", properties)
        onSelectConnectionMethod(method)
    }

    private func startTailscalePairing() {
        // Scanning a pairing code is Tailscale pairing, so every scan
        // entrypoint adopts the method first. The fallback's scan action can
        // fire while automatic is still selected, and the root's
        // manual-pairing gate re-reads the store synchronously, so the
        // scanner presents instead of silently no-oping.
        onSelectConnectionMethod(.tailscale)
        diagnosticLog?.recordAppEvent(.onboardingPairingStarted)
        var properties = eventProperties
        properties["source"] = .string("tailscale_choice")
        analytics.capture("ios_onboarding_pairing_started", properties)
        onStartTailscalePairing()
    }

    private func captureSceneViewed() {
        diagnosticLog?.recordAppEvent(.onboardingStageViewed)
        var properties = eventProperties
        properties["surface"] = .string(stage.analyticsValue)
        analytics.capture("ios_onboarding_scene_viewed", properties)
    }

    private var eventProperties: [String: AnalyticsValue] {
        [
            "context": .string(context.rawValue),
            "stage": .string(stage.analyticsValue)
        ]
    }
}
#endif
