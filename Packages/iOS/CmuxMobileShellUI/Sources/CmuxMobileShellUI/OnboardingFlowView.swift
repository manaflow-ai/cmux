#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI

/// A short product demonstration that hands directly into authentication and
/// computer pairing without duplicating either production flow.
struct OnboardingFlowView: View {
    let context: OnboardingContext
    let isAuthenticated: Bool
    let isMacReady: Bool
    let onReachedConnection: () -> Void
    let onSkip: () -> Void
    let onStartPairing: () -> Void
    let onComplete: () -> Void
    var setupHelpHighlight: MobileSetupGuidanceState? = .signedInNeverPaired

    @State private var stage: OnboardingStage
    @State private var isShowingSetupHelp = false
    @Environment(\.analytics) private var analytics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        initialStage: OnboardingStage,
        context: OnboardingContext,
        isAuthenticated: Bool,
        isMacReady: Bool,
        onReachedConnection: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onStartPairing: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        setupHelpHighlight: MobileSetupGuidanceState? = .signedInNeverPaired
    ) {
        self.context = context
        self.isAuthenticated = isAuthenticated
        self.isMacReady = isMacReady
        self.onReachedConnection = onReachedConnection
        self.onSkip = onSkip
        self.onStartPairing = onStartPairing
        self.onComplete = onComplete
        self.setupHelpHighlight = setupHelpHighlight
        _stage = State(initialValue: initialStage)
    }

    var body: some View {
        scene
            .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: stage)
            .interactiveDismissDisabled()
            .sheet(isPresented: $isShowingSetupHelp) {
                SetupHelpView(highlight: setupHelpHighlight) {
                    isShowingSetupHelp = false
                }
            }
            .onAppear { captureSceneViewed() }
            .onChange(of: stage) { _, _ in captureSceneViewed() }
            .onChange(of: isAuthenticated) { _, _ in captureSceneViewed() }
    }

    @ViewBuilder
    private var scene: some View {
        if stage == .connect && !isAuthenticated {
            OnboardingSignInBridgeView(onBack: showHandoff)
        } else {
            switch stage {
            case .agents:
                OnboardingAgentsView(
                    onSkip: skip,
                    onContinue: showHandoff
                )
            case .handoff:
                OnboardingHandoffView(
                    isMacReady: isMacReady,
                    onBack: showAgents,
                    onSkip: skip,
                    onRespond: captureDemoReply,
                    onContinue: showConnection
                )
            case .connect:
                OnboardingConnectionView(
                    isMacReady: isMacReady,
                    onBack: showHandoff,
                    onPrimary: finishOrPair,
                    onHelp: showHelp
                )
            }
        }
    }

    private func showAgents() {
        stage = .agents
    }

    private func showHandoff() {
        stage = .handoff
    }

    private func showConnection() {
        onReachedConnection()
        stage = .connect
    }

    private func skip() {
        analytics.capture("ios_onboarding_skipped", eventProperties)
        onSkip()
    }

    private func finishOrPair() {
        if isMacReady {
            analytics.capture("ios_onboarding_completed", eventProperties)
            onComplete()
        } else {
            analytics.capture("ios_onboarding_pairing_started", eventProperties)
            onStartPairing()
        }
    }

    private func showHelp() {
        analytics.capture("ios_onboarding_help_opened", eventProperties)
        isShowingSetupHelp = true
    }

    private func captureDemoReply() {
        analytics.capture("ios_onboarding_demo_replied", eventProperties)
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
