#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// A short product tour that hands directly into authentication and same-account
/// computer discovery, with QR available only as fallback.
struct OnboardingFlowView: View {
    let context: OnboardingContext
    let isAuthenticated: Bool
    let connectionPhase: OnboardingConnectionPhase
    let onReachedConnection: () -> Void
    let onSkip: () -> Void
    let onRetryConnection: () -> Void
    let onStartFallbackPairing: () -> Void
    let onComplete: () -> Void

    @State private var stage: OnboardingStage
    @State private var transitionDirection = OnboardingTransitionDirection.forward
    @Environment(\.analytics) private var analytics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        initialStage: OnboardingStage,
        context: OnboardingContext,
        isAuthenticated: Bool,
        connectionPhase: OnboardingConnectionPhase,
        onReachedConnection: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onRetryConnection: @escaping () -> Void,
        onStartFallbackPairing: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.context = context
        self.isAuthenticated = isAuthenticated
        self.connectionPhase = connectionPhase
        self.onReachedConnection = onReachedConnection
        self.onSkip = onSkip
        self.onRetryConnection = onRetryConnection
        self.onStartFallbackPairing = onStartFallbackPairing
        self.onComplete = onComplete
        _stage = State(initialValue: initialStage)
    }

    var body: some View {
        ZStack {
            scene
                .id(stage)
                .transition(sceneTransition)
        }
        .clipped()
        .interactiveDismissDisabled()
        .onAppear { captureSceneViewed() }
        .onChange(of: stage) { _, _ in captureSceneViewed() }
        .onChange(of: isAuthenticated) { _, _ in captureSceneViewed() }
        .onChange(of: connectionPhase) { _, _ in captureSceneViewed() }
    }

    private var sceneTransition: AnyTransition {
        reduceMotion ? .identity : .push(from: transitionDirection.pushEdge)
    }

    @ViewBuilder
    private var scene: some View {
        if stage == .connect && !isAuthenticated {
            OnboardingSignInBridgeView(onBack: showReserved)
        } else {
            switch stage {
            case .agents:
                OnboardingAgentsView(
                    onSkip: skip,
                    onContinue: showReserved
                )
            case .reserved:
                OnboardingReservedView(
                    onBack: showAgents,
                    onSkip: skip,
                    onContinue: showConnection
                )
            case .connect:
                OnboardingConnectionView(
                    phase: connectionPhase,
                    onBack: showReserved,
                    onPrimary: finishOrRetry,
                    onFallback: startFallbackPairing
                )
            }
        }
    }

    private func showAgents() {
        navigate(to: .agents)
    }

    private func showReserved() {
        navigate(to: .reserved)
    }

    private func showConnection() {
        onReachedConnection()
        navigate(to: .connect)
    }

    private func navigate(to destination: OnboardingStage) {
        guard destination != stage else { return }

        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            transitionDirection = OnboardingTransitionDirection(
                from: stage,
                to: destination
            )
            stage = destination
        }
    }

    private func skip() {
        analytics.capture("ios_onboarding_skipped", eventProperties)
        onSkip()
    }

    private func finishOrRetry() {
        switch connectionPhase {
        case .searching:
            break
        case .fallback:
            analytics.capture("ios_onboarding_connection_retried", eventProperties)
            onRetryConnection()
        case .ready:
            analytics.capture("ios_onboarding_completed", eventProperties)
            onComplete()
        }
    }

    private func startFallbackPairing() {
        var properties = eventProperties
        properties["source"] = .string("qr_fallback")
        analytics.capture("ios_onboarding_pairing_started", properties)
        onStartFallbackPairing()
    }

    private func captureSceneViewed() {
        var properties = eventProperties
        properties["surface"] = .string(
            stage == .connect && !isAuthenticated ? "sign_in" : stage.analyticsValue
        )
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
