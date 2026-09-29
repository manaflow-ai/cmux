#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A short product tour presented after sign-in, ending in same-account
/// computer discovery with explicit Mac-side pairing opt-in.
struct OnboardingFlowView: View {
    let context: OnboardingContext
    let isAuthenticated: Bool
    let connectionPhase: OnboardingConnectionPhase
    let keepAwakeOffer: OnboardingKeepAwakeOffer?
    let onEnablePush: () async -> Bool
    let onReachedConnection: () -> Void
    let onSkip: () -> Void
    let onRetryConnection: () -> Void
    let onSetKeepAwake: (Bool) async -> Bool
    let onComplete: () -> Void

    @State private var stage: OnboardingStage
    @State private var didReachConnection = false
    @State private var didRecordStart = false
    @State private var isPushEnableInFlight = false
    @Environment(\.analytics) private var analytics
    @Environment(\.mobileDiagnosticLog) private var diagnosticLog

    init(
        initialStage: OnboardingStage,
        context: OnboardingContext,
        isAuthenticated: Bool,
        connectionPhase: OnboardingConnectionPhase,
        keepAwakeOffer: OnboardingKeepAwakeOffer? = nil,
        onEnablePush: @escaping () async -> Bool,
        onReachedConnection: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onRetryConnection: @escaping () -> Void,
        onSetKeepAwake: @escaping (Bool) async -> Bool = { _ in false },
        onComplete: @escaping () -> Void
    ) {
        self.context = context
        self.isAuthenticated = isAuthenticated
        self.connectionPhase = connectionPhase
        self.keepAwakeOffer = keepAwakeOffer
        self.onEnablePush = onEnablePush
        self.onReachedConnection = onReachedConnection
        self.onSkip = onSkip
        self.onRetryConnection = onRetryConnection
        self.onSetKeepAwake = onSetKeepAwake
        self.onComplete = onComplete
        _stage = State(initialValue: initialStage)
    }

    var body: some View {
        OnboardingSceneContainer(
            stage: stage,
            chrome: chrome,
            onBack: handleBack,
            onSkip: skip,
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
            reachConnectionIfNeeded()
        }
        .onChange(of: stage) { _, _ in
            captureSceneViewed()
            reachConnectionIfNeeded()
        }
        .onChange(of: isAuthenticated) { _, isNowAuthenticated in
            guard stage == .connect else { return }
            captureSceneViewed()
            if isNowAuthenticated {
                onReachedConnection()
            }
        }
    }

    private var chrome: OnboardingSceneChrome {
        OnboardingSceneChrome(
            stage: stage,
            isAuthenticated: isAuthenticated,
            connectionPhase: connectionPhase
        )
    }

    @ViewBuilder
    private func page(for pageStage: OnboardingStage) -> some View {
        switch pageStage {
        case .agents:
            OnboardingAgentsView()
        case .notifications:
            OnboardingNotificationsView()
        case .push:
            OnboardingPushView()
        case .pairing:
            OnboardingPairingView()
        case .connect:
            OnboardingConnectionView(
                phase: connectionPhase,
                keepAwakeOffer: keepAwakeOffer,
                onSetKeepAwake: setKeepAwake
            )
        }
    }

    private func handleBack() {
        switch stage {
        case .agents:
            break
        case .notifications:
            showAgents()
        case .push:
            showNotifications()
        case .pairing:
            showPush()
        case .connect:
            showPairing()
        }
    }

    private func handlePrimary() {
        switch stage {
        case .agents:
            showNotifications()
        case .notifications:
            showPush()
        case .push:
            enablePush()
        case .pairing:
            showConnection()
        case .connect:
            if isAuthenticated {
                finishOrRetry()
            } else {
                finishBeforeAuthentication()
            }
        }
    }

    private func showAgents() {
        navigate(to: .agents)
    }

    private func showNotifications() {
        navigate(to: .notifications)
    }

    private func showPush() {
        navigate(to: .push)
    }

    private func showPairing() {
        navigate(to: .pairing)
    }

    private func showConnection() {
        navigate(to: .connect)
    }

    /// The one place the app first asks the OS for notification permission.
    /// Advances to Pairing after the system alert resolves either way; the
    /// grant/deny outcome is recorded by the push coordinator.
    private func enablePush() {
        guard !isPushEnableInFlight else { return }
        isPushEnableInFlight = true
        analytics.capture("ios_onboarding_push_enable_tapped", eventProperties)
        // The enable must outlive a page change: the coordinator finishes
        // registration regardless, and re-tapping is barred by the flag.
        Task { @MainActor in
            _ = await onEnablePush()
            isPushEnableInFlight = false
            if stage == .push {
                showPairing()
            }
        }
    }

    private func declinePush() {
        analytics.capture("ios_onboarding_push_declined", eventProperties)
        showPairing()
    }

    private func reachConnectionIfNeeded() {
        guard stage == .connect, !didReachConnection else { return }
        didReachConnection = true
        onReachedConnection()
    }

    private func navigate(to destination: OnboardingStage) {
        guard destination != stage else { return }
        stage = destination
    }

    private func skip() {
        diagnosticLog?.recordAppEvent(.onboardingSkipped)
        analytics.capture("ios_onboarding_skipped", eventProperties)
        onSkip()
    }

    private func finishOrRetry() {
        switch connectionPhase {
        case .idle:
            diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
            onRetryConnection()
        case .searching:
            break
        case .fallback:
            diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
            analytics.capture("ios_onboarding_connection_retried", eventProperties)
            onRetryConnection()
        case .ready:
            diagnosticLog?.recordAppEvent(.onboardingCompleted)
            analytics.capture("ios_onboarding_completed", eventProperties)
            onComplete()
        }
    }

    /// Push's secondary action declines the opt-in without touching the OS.
    /// Once Enable is in flight the pending system alert owns the decision, so
    /// a racing Not Now tap is ignored rather than recorded as a contradictory
    /// intent. Connect has no secondary manual-pairing action.
    private func handleSecondary() {
        guard stage == .push, !isPushEnableInFlight else { return }
        declinePush()
    }

    private func setKeepAwake(_ enabled: Bool) async {
        var properties = eventProperties
        properties["enabled"] = .bool(enabled)
        analytics.capture("ios_onboarding_keep_awake_set", properties)
        let confirmed = await onSetKeepAwake(enabled)
        if !confirmed {
            properties["enabled"] = .bool(!enabled)
            analytics.capture("ios_onboarding_keep_awake_reverted", properties)
        }
    }

    private func finishBeforeAuthentication() {
        analytics.capture("ios_onboarding_tour_completed", eventProperties)
        onComplete()
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
