#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The first-run welcome tour container.
///
/// Owns the stage pipeline (chrome, progress, transitions, footer actions)
/// and defers all durable effects to the injected callbacks, so the same view
/// serves first run (root gate), Settings replay, and the deterministic
/// UI-test preview. Stage membership is recomputed live by
/// ``WelcomeStagePlan``: when sign-in or the notification decision resolves
/// while its stage is on screen, the tour advances by itself.
struct WelcomeTourView: View {
    /// Which host presents the tour, controlling durable side effects.
    enum Context {
        /// The root-gate first run: reaching connect persists resume progress.
        case firstRun
        /// Settings re-entry: nothing persists, completion just dismisses.
        case replay
        /// The deterministic UI-test harness: like replay, with instant demo
        /// playback.
        case preview
    }

    let context: Context
    let initialStage: WelcomeStage
    let isAuthenticated: Bool
    let needsNotificationDecision: Bool
    let connection: WelcomeConnectionStatus
    let connectionMethod: MobileConnectionMethod
    let accountEmail: String?
    let selectConnectionMethod: (MobileConnectionMethod) -> Void
    let requestNotifications: () async -> Bool
    let reachedConnectStage: () -> Void
    let retryConnection: () -> Void
    let scanPairingCode: () -> Void
    let skip: () -> Void
    let finish: () -> Void

    /// The stage the person last navigated to; the plan resolves what shows.
    @State private var requestedStage: WelcomeStage
    @State private var isRequestingNotifications = false
    /// Stages whose entry effects already fired this presentation.
    @State private var enteredStages: Set<WelcomeStage> = []
    /// When the tour appeared, for the completion/skip events' `duration_ms`.
    @State private var tourStartedAt: Date?
    /// When the connect stage first entered, for stage-level time-to-link.
    @State private var connectEnteredAt: Date?
    /// Whether the connect-linked funnel event already fired this presentation.
    @State private var reportedConnectLinked = false
    @Environment(\.analytics) private var analytics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        context: Context,
        initialStage: WelcomeStage = .hello,
        isAuthenticated: Bool,
        needsNotificationDecision: Bool,
        connection: WelcomeConnectionStatus,
        connectionMethod: MobileConnectionMethod,
        accountEmail: String?,
        selectConnectionMethod: @escaping (MobileConnectionMethod) -> Void,
        requestNotifications: @escaping () async -> Bool,
        reachedConnectStage: @escaping () -> Void,
        retryConnection: @escaping () -> Void,
        scanPairingCode: @escaping () -> Void,
        skip: @escaping () -> Void,
        finish: @escaping () -> Void
    ) {
        self.context = context
        self.initialStage = initialStage
        self.isAuthenticated = isAuthenticated
        self.needsNotificationDecision = needsNotificationDecision
        self.connection = connection
        self.connectionMethod = connectionMethod
        self.accountEmail = accountEmail
        self.selectConnectionMethod = selectConnectionMethod
        self.requestNotifications = requestNotifications
        self.reachedConnectStage = reachedConnectStage
        self.retryConnection = retryConnection
        self.scanPairingCode = scanPairingCode
        self.skip = skip
        self.finish = finish
        _requestedStage = State(initialValue: initialStage)
    }

    private var plan: WelcomeStagePlan {
        WelcomeStagePlan(
            isAuthenticated: isAuthenticated,
            needsNotificationDecision: needsNotificationDecision
        )
    }

    private var stage: WelcomeStage {
        plan.resolved(requestedStage)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                stageContent
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .background(PlatformPalette.systemBackground)
        .accessibilityIdentifier("MobileWelcomeTour")
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: stage)
        .onAppear {
            if tourStartedAt == nil {
                tourStartedAt = Date()
            }
            stageDidEnter(stage)
        }
        .onChange(of: stage) { _, newStage in
            stageDidEnter(newStage)
        }
        .onChange(of: connection) { previous, current in
            if case .linked = current, previous != current, stage == .connect {
                MobileHapticFeedback().notification(.success)
                reportConnectLinked()
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        ZStack {
            progressDots
            HStack {
                if let previous = plan.previous(before: stage) {
                    Button {
                        requestedStage = previous
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel(L10n.string(
                        "mobile.welcome.back",
                        defaultValue: "Back"
                    ))
                    .accessibilityIdentifier("MobileWelcomeBack")
                }
                Spacer()
                if showsSkip {
                    Button(L10n.string("mobile.welcome.skip", defaultValue: "Skip")) {
                        skipTour()
                    }
                    .accessibilityIdentifier("MobileWelcomeSkip")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// The connect stage exits through the footer ("Set Up Later" / "Done"),
    /// so its header stays clean.
    private var showsSkip: Bool {
        stage != .connect
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(Array(plan.stages.enumerated()), id: \.element) { index, _ in
                Circle()
                    .fill(
                        index <= plan.position(of: stage)
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.quaternary)
                    )
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: L10n.string(
                "mobile.welcome.progressFormat",
                defaultValue: "Step %1$d of %2$d"
            ),
            plan.position(of: stage) + 1,
            plan.stages.count
        ))
        .accessibilityIdentifier("MobileWelcomeProgress")
    }

    // MARK: Stages

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .hello:
            WelcomeHelloStageView(revealsInstantly: context == .preview)
        case .notifications:
            WelcomeNotificationsStageView()
        case .signIn:
            WelcomeSignInStageView()
        case .connect:
            WelcomeConnectStageView(
                status: connection,
                method: connectionMethod,
                accountEmail: accountEmail,
                selectMethod: { method in
                    analytics.capture(
                        "ios_welcome_method_selected",
                        ["method": .string(method.rawValue)]
                    )
                    selectConnectionMethod(method)
                },
                scanPairingCode: scanPairingCode
            )
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            switch stage {
            case .hello:
                primaryButton(
                    L10n.string("mobile.welcome.continue", defaultValue: "Continue")
                ) {
                    advance()
                }
            case .notifications:
                primaryButton(
                    L10n.string(
                        "mobile.welcome.notifications.enable",
                        defaultValue: "Enable Notifications"
                    ),
                    isLoading: isRequestingNotifications
                ) {
                    enableNotifications()
                }
                secondaryButton(
                    L10n.string("mobile.welcome.notifications.later", defaultValue: "Not Now")
                ) {
                    analytics.capture(
                        "ios_welcome_notifications_choice",
                        ["choice": .string("deferred")]
                    )
                    advance()
                }
                .disabled(isRequestingNotifications)
            case .signIn:
                // SignInView owns its calls to action; the tour advances by
                // itself when authentication lands.
                EmptyView()
            case .connect:
                connectFooter
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var connectFooter: some View {
        switch connection {
        case .linked:
            primaryButton(
                L10n.string("mobile.welcome.connect.start", defaultValue: "Start Using cmux")
            ) {
                finishTour(connected: true)
            }
        case .stalled:
            primaryButton(
                L10n.string("mobile.welcome.connect.retry", defaultValue: "Search Again")
            ) {
                retryConnection()
            }
            secondaryButton(deferConnectTitle) { finishTour(connected: false) }
        case .searching:
            secondaryButton(deferConnectTitle) { finishTour(connected: false) }
        }
    }

    private var deferConnectTitle: String {
        switch context {
        case .firstRun:
            L10n.string("mobile.welcome.connect.later", defaultValue: "Set Up Later")
        case .replay, .preview:
            L10n.string("mobile.welcome.done", defaultValue: "Done")
        }
    }

    private func primaryButton(
        _ title: String,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .mobileGlassProminentButton()
        .disabled(isLoading)
        .accessibilityIdentifier("MobileWelcomePrimary")
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("MobileWelcomeSecondary")
    }

    // MARK: Actions

    private func advance() {
        if let next = plan.next(after: stage) {
            requestedStage = next
        }
    }

    private func enableNotifications() {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        // Capture the on-screen stage now: once the permission resolves, the
        // plan drops this stage, and advancing from the live (already resolved
        // forward) stage would skip its successor.
        let from = stage
        Task {
            let granted = await requestNotifications()
            analytics.capture(
                "ios_welcome_notifications_choice",
                ["choice": .string(granted ? "granted" : "denied")]
            )
            isRequestingNotifications = false
            if let next = plan.next(after: from) {
                requestedStage = next
            }
        }
    }

    private func skipTour() {
        var props: [String: AnalyticsValue] = ["stage": .string(stage.rawValue)]
        if let ms = elapsedMs(since: tourStartedAt) {
            props["duration_ms"] = .int(ms)
        }
        analytics.capture("ios_welcome_skipped", props)
        skip()
    }

    private func finishTour(connected: Bool) {
        var props: [String: AnalyticsValue] = ["connected": .bool(connected)]
        if let ms = elapsedMs(since: tourStartedAt) {
            props["duration_ms"] = .int(ms)
        }
        analytics.capture("ios_welcome_completed", props)
        finish()
    }

    /// Emits stage-level time-to-link once: first entering connect to seeing
    /// `.linked`. The UX-side complement of the transport's
    /// `ios_pairing_succeeded` duration, this one includes reading the
    /// checklist, installing cmux on the Mac, and retries.
    private func reportConnectLinked() {
        guard !reportedConnectLinked else { return }
        reportedConnectLinked = true
        var props: [String: AnalyticsValue] = [
            "method": .string(connectionMethod.rawValue)
        ]
        if let ms = elapsedMs(since: connectEnteredAt) {
            props["duration_ms"] = .int(ms)
        }
        analytics.capture("ios_welcome_connect_linked", props)
    }

    private func elapsedMs(since start: Date?) -> Int? {
        guard let start else { return nil }
        return max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func stageDidEnter(_ stage: WelcomeStage) {
        guard !enteredStages.contains(stage) else { return }
        enteredStages.insert(stage)
        if stage == .connect, connectEnteredAt == nil {
            connectEnteredAt = Date()
        }
        analytics.capture(
            "ios_welcome_stage_viewed",
            ["stage": .string(stage.rawValue)]
        )
        if stage == .connect {
            reachedConnectStage()
        }
    }
}
#endif
