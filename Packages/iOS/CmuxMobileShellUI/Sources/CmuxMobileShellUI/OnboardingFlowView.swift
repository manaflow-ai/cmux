#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A short product tour that routes into authentication after the tour, then
/// same-account computer discovery, with pairing available for Tailscale.
struct OnboardingFlowView: View {
    let context: OnboardingContext
    let isAuthenticated: Bool
    let connectionPhase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void
    let onEnablePush: () async -> Bool
    let onReachedConnection: () -> Void
    let onSkip: () -> Void
    let onRetryConnection: () -> Void
    let onStartTailscalePairing: () -> Void
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
        connectionMethod: MobileConnectionMethod = .automatic,
        onSelectConnectionMethod: @escaping (MobileConnectionMethod) -> Void = { _ in },
        onEnablePush: @escaping () async -> Bool,
        onReachedConnection: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onRetryConnection: @escaping () -> Void,
        onStartTailscalePairing: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.context = context
        self.isAuthenticated = isAuthenticated
        self.connectionPhase = connectionPhase
        self.connectionMethod = connectionMethod
        self.onSelectConnectionMethod = onSelectConnectionMethod
        self.onEnablePush = onEnablePush
        self.onReachedConnection = onReachedConnection
        self.onSkip = onSkip
        self.onRetryConnection = onRetryConnection
        self.onStartTailscalePairing = onStartTailscalePairing
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
            connectionPhase: connectionPhase,
            connectionMethod: connectionMethod
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
        case .connect:
            OnboardingConnectionView(
                phase: connectionPhase,
                connectionMethod: connectionMethod,
                onSelectConnectionMethod: selectConnectionMethod
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
        case .connect:
            showPush()
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

    private func showConnection() {
        navigate(to: .connect)
    }

    /// The one place the app first asks the OS for notification permission.
    /// Advances to Connect after the system alert resolves either way; the
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
                showConnection()
            }
        }
    }

    private func declinePush() {
        analytics.capture("ios_onboarding_push_declined", eventProperties)
        showConnection()
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
            if connectionMethod == .tailscale {
                startTailscalePairing()
            } else {
                diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
                onRetryConnection()
            }
        case .searching:
            break
        case .fallback:
            if connectionMethod == .tailscale {
                startTailscalePairing()
            } else {
                diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
                analytics.capture("ios_onboarding_connection_retried", eventProperties)
                onRetryConnection()
            }
        case .ready:
            diagnosticLog?.recordAppEvent(.onboardingCompleted)
            analytics.capture("ios_onboarding_completed", eventProperties)
            onComplete()
        }
    }

    /// Push's secondary action declines the opt-in without touching the OS.
    /// Once Enable is in flight the pending system alert owns the decision, so
    /// a racing Not Now tap is ignored rather than recorded as a contradictory
    /// intent. On Connect, Tailscale's secondary action retries discovery;
    /// Auto-Connect has no secondary manual-pairing action.
    private func handleSecondary() {
        if stage == .push {
            guard !isPushEnableInFlight else { return }
            declinePush()
            return
        }
        guard connectionMethod == .tailscale, connectionPhase == .fallback else { return }
        diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
        analytics.capture("ios_onboarding_connection_retried", eventProperties)
        onRetryConnection()
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
        diagnosticLog?.recordAppEvent(.onboardingPairingStarted)
        var properties = eventProperties
        properties["source"] = .string("tailscale_choice")
        analytics.capture("ios_onboarding_pairing_started", properties)
        onStartTailscalePairing()
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
