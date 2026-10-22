import CMUXMobileCore
import Foundation

/// Processes ``ProductAnalyticsCommand``s in order, off the caller's thread:
/// deduplicates, derives funnel events, merges the shared context and hands
/// the result to the sink.
actor ProductAnalyticsPipeline {
    /// How long after an upgrade click a newly paid plan is attributed to it.
    static let upgradeAttributionWindow: TimeInterval = 7 * 24 * 60 * 60
    static let maximumTrackedAgentSessions = 1_024

    private let sink: any AnalyticsEmitting
    private var ledger: ProductAnalyticsLedger
    private var context: ProductAnalyticsContext
    private let isPreexistingInstall: Bool
    private let now: @Sendable () -> Date
    private var shownThisLaunch: Set<String> = []
    /// Sessions seen this launch, with whether their start was counted.
    private var agentSessions: [String: (agent: AgentKind, counted: Bool)] = [:]
    /// Session ids in first-seen order, for oldest-first eviction.
    private var agentSessionOrder: [String] = []
    private var identifiedUserID: String?
    private var consecutiveCreateFailures = 0

    init(
        sink: any AnalyticsEmitting,
        ledger: ProductAnalyticsLedger,
        context: ProductAnalyticsContext,
        isPreexistingInstall: Bool,
        now: @escaping @Sendable () -> Date
    ) {
        self.sink = sink
        self.ledger = ledger
        self.context = context
        self.isPreexistingInstall = isPreexistingInstall
        self.now = now
    }

    func run(_ commands: AsyncStream<ProductAnalyticsCommand>) async {
        for await command in commands {
            handle(command)
        }
    }

    private func handle(_ command: ProductAnalyticsCommand) {
        switch command {
        case .launch:
            launch()
        case let .track(event):
            track(event)
        case let .milestone(milestone):
            reach(milestone)
        case let .feature(feature):
            guard ledger.claimFeatureDay(feature, day: Self.utcDay(now())) else { return }
            track(.featureUsed(feature: feature))
        case let .context(change):
            apply(change)
        case let .identify(userID):
            identify(userID: userID)
        case .signOut:
            signOut()
        case let .plan(accountID, isPaid):
            notePlan(accountID: accountID, isPaid: isPaid)
        case let .agentHook(source, sessionID, phase):
            noteAgentHook(source: source, sessionID: sessionID, phase: phase)
        case let .cloudRequest(observation):
            noteCloudRequest(observation)
        case let .machineCreateFinished(succeeded, errorCode, seconds):
            noteMachineCreateFinished(succeeded: succeeded, errorCode: errorCode, seconds: seconds)
        case let .barrier(continuation):
            continuation.resume()
        }
    }

    // MARK: - Capture

    private func track(_ event: ProductAnalyticsEvent) {
        switch event {
        case let .upgradePromptShown(source, _):
            guard shownThisLaunch.insert("\(event.name)|\(source)").inserted else { return }
        case .cloudButtonShown:
            guard shownThisLaunch.insert(event.name).inserted else { return }
        default:
            break
        }
        var properties = context.properties
        properties.merge(event.properties) { _, eventValue in eventValue }
        sink.capture(event.name, properties)
        followUp(after: event)
    }

    /// Milestones and ledger updates implied by an event, so call sites
    /// report the action once.
    private func followUp(after event: ProductAnalyticsEvent) {
        switch event {
        case let .upgradeEntrypointOpened(source, _, _):
            ledger.recordUpgradeClick(source: source, account: identifiedUserID, at: now())
            reach(.firstUpgradeClick)
        case .signInSucceeded:
            reach(.firstSignIn)
        case .cloudEnableCompleted(.success):
            reach(.firstCloudEnable)
        case .cloudMachineCreateSucceeded:
            reach(.firstCloudMachine)
        case .cloudWorkspaceCreated:
            reach(.firstCloudWorkspace)
        case .agentSessionStarted:
            reach(.firstAgentSession)
        case .planActivated:
            reach(.firstPaidPlan)
        case .featureUsed(.split):
            reach(.firstSplit)
        case .featureUsed(.browserPane):
            reach(.firstBrowserPane)
        default:
            break
        }
    }

    private func reach(_ milestone: ActivationMilestone) {
        guard ledger.claimMilestone(milestone) else { return }
        let firstSeen = ledger.installFirstSeenAt ?? now()
        let days = max(0, Int(now().timeIntervalSince(firstSeen) / 86_400))
        track(.activationMilestoneReached(milestone: milestone, isNewInstall: ledger.installIsNew, daysSinceInstall: days))
    }

    // MARK: - Launch and context

    private func launch() {
        sink.setSuperProperties(context.properties)
        let install = ledger.registerInstall(now: now(), isPreexisting: isPreexistingInstall)
        if install.isNewInstall {
            reach(.firstLaunch)
        } else if install.isFirstRun {
            // An install from before this catalog: its first launch already
            // happened, unrecorded. Claim it silently so it never fires late.
            _ = ledger.claimMilestone(.firstLaunch)
        }
        let previous = ledger.swapLastVersion(context.appVersion)
        if let previous, previous != context.appVersion,
           let direction = Self.direction(from: previous, to: context.appVersion) {
            track(.appUpdated(direction: direction, fromVersion: previous, toVersion: context.appVersion))
        }
    }

    private func apply(_ change: ProductAnalyticsContextChange) {
        var next = context
        switch change {
        case let .signedIn(value): next.isSignedIn = value
        case let .plan(value): next.plan = value
        case let .cloudEnabled(value): next.cloudEnabled = value
        case let .workspacesOpen(value): next.workspacesOpen = value
        }
        guard next != context else { return }
        context = next
        sink.setSuperProperties(context.properties)
    }

    // MARK: - Identity

    private func identify(userID: String) {
        if identifiedUserID != userID {
            identifiedUserID = userID
            sink.identify(userId: userID, alias: nil, properties: ["stack_user_id": .string(userID)])
        }
        apply(.signedIn(true))
    }

    private func signOut() {
        guard identifiedUserID != nil || context.isSignedIn else { return }
        // Captured before the reset so the sign-out joins the signed-in person.
        track(.signedOut)
        identifiedUserID = nil
        context.isSignedIn = false
        context.plan = .unknown
        sink.identify(userId: nil, alias: nil, properties: [:])
        sink.setSuperProperties(context.properties)
    }

    private func notePlan(accountID: String, isPaid: Bool) {
        apply(.plan(isPaid ? .paid : .free))
        let previous = ledger.swapPlan(account: accountID, isPaid: isPaid)
        if isPaid, previous != true {
            let click = ledger.upgradeClick(for: accountID).flatMap { click -> (source: String, at: Date)? in
                now().timeIntervalSince(click.at) <= Self.upgradeAttributionWindow ? click : nil
            }
            // A first sighting of a paid account is an activation only right
            // after an upgrade click; otherwise it is an existing subscriber.
            guard previous == false || click != nil else { return }
            // One click attributes one activation.
            if click != nil { ledger.clearUpgradeClick() }
            track(.planActivated(
                upgradeSource: click?.source,
                sinceUpgradeClick: click.map { DurationBucket(seconds: now().timeIntervalSince($0.at)) }
            ))
        } else if !isPaid, previous == true {
            track(.planDeactivated)
        }
    }

    // MARK: - Agents

    private func noteAgentHook(source: String, sessionID: String, phase: AgentHookPhase) {
        guard !sessionID.isEmpty else { return }
        switch phase {
        case .sessionEnd:
            guard let session = agentSessions.removeValue(forKey: sessionID) else { return }
            agentSessionOrder.removeAll { $0 == sessionID }
            // Ends pair with counted starts, so started minus ended stays meaningful.
            if session.counted { track(.agentSessionEnded(agent: session.agent)) }
        case .sessionStart, .activity:
            guard agentSessions[sessionID] == nil else { return }
            if agentSessionOrder.count >= Self.maximumTrackedAgentSessions {
                agentSessions.removeValue(forKey: agentSessionOrder.removeFirst())
            }
            let agent = AgentKind(hookSource: source)
            agentSessions[sessionID] = (agent, phase == .sessionStart)
            agentSessionOrder.append(sessionID)
            // Only a SessionStart is a new session. Activity from a session the
            // app first sees mid-flight (it outlived a relaunch) is tracked so
            // its end counts, but it is not started again.
            if phase == .sessionStart {
                track(.agentSessionStarted(agent: agent))
            }
        }
    }

    // MARK: - Cloud

    /// Creates are reported by ``noteMachineCreateFinished(succeeded:errorCode:seconds:)``,
    /// which sees every launcher; their requests are skipped here so a create
    /// counts once.
    private func noteCloudRequest(_ request: CloudRequestObservation) {
        let errorCode = request.errorCode ?? (request.success ? nil : "unknown")
        if errorCode == "cancelled" { return }
        if request.method == "POST", request.route == "/api/vm" { return }
        let duration = DurationBucket(seconds: request.durationMs / 1_000)
        let isMachineSubresource = request.route.hasPrefix("/api/vm/{id}")
        switch (request.method, request.route) {
        case ("DELETE", "/api/vm/{id}"):
            if request.success { track(.cloudMachineDeleted) }
        case (_, "/api/vm/{id}/attach-endpoint"):
            track(.cloudMachineAttached(
                success: request.success,
                latency: duration,
                errorClass: errorCode.map(CloudErrorClass.init(errorCode:))
            ))
        default:
            break
        }
        if let errorCode, let limit = CloudPlanLimit(errorCode: errorCode) {
            let operation: String
            switch (request.method, request.route) {
            case (_, "/api/vm/{id}/resize"): operation = "resize"
            case (_, "/api/vm/restore"): operation = "restore"
            case (_, "/api/vm/{id}/fork"): operation = "fork"
            default: operation = isMachineSubresource ? "machine_action" : "other"
            }
            track(.cloudPlanLimitHit(limit: limit, operation: operation))
        }
    }

    private func noteMachineCreateFinished(succeeded: Bool, errorCode: String?, seconds: Double) {
        if succeeded {
            consecutiveCreateFailures = 0
            track(.cloudMachineCreateSucceeded(duration: DurationBucket(seconds: seconds)))
            return
        }
        let code = errorCode ?? "unknown"
        consecutiveCreateFailures += 1
        track(.cloudMachineCreateFailed(
            errorClass: CloudErrorClass(errorCode: code),
            errorCode: code,
            consecutiveFailures: consecutiveCreateFailures
        ))
        if let limit = CloudPlanLimit(errorCode: code) {
            track(.cloudPlanLimitHit(limit: limit, operation: "create"))
        }
    }

    // MARK: - Helpers

    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Compares dotted numeric versions; nil when either is not one.
    static func direction(from previous: String, to current: String) -> AppUpdateDirection? {
        let lhs = previous.split(separator: ".").map { Int($0) }
        let rhs = current.split(separator: ".").map { Int($0) }
        guard !lhs.isEmpty, !rhs.isEmpty, !lhs.contains(nil), !rhs.contains(nil) else { return nil }
        let left = lhs.compactMap { $0 }
        let right = rhs.compactMap { $0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .upgrade : .downgrade }
        }
        return nil
    }
}
