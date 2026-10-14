public import CMUXMobileCore

/// One product analytics event from the macOS app. This enum is the event
/// catalog: every name and property the app sends is declared here, pinned by
/// `ProductAnalyticsEventCatalogTests`, and documented in
/// `docs/posthog/mac-product-analytics.md`.
///
/// Names follow `cmux_<object>_<action>` in snake_case, matching the server's
/// `cmux_billing_*` events so client and server steps share one funnel.
/// Properties are enums, counts, booleans and buckets only: never terminal
/// content, paths, commands, prompts, hostnames, emails or raw error text.
///
/// The shared context (``ProductAnalyticsContext``) is merged into every event
/// by ``ProductAnalytics``, so cases carry only what is specific to them.
///
/// ```swift
/// analytics.track(.upgradePromptShown(source: "mac_sidebar_badge", plan: "pro"))
/// ```
public enum ProductAnalyticsEvent: Sendable, Equatable {
    // MARK: Upgrade funnel

    /// An upgrade entrypoint became visible. Deduplicated per source per launch.
    case upgradePromptShown(source: String, plan: String)
    /// An upgrade entrypoint was clicked. `source` is the `ProUpgradeSource`
    /// token that also travels to checkout as `cmux_source`.
    case upgradeEntrypointOpened(source: String, plan: String, destination: UpgradeDestination)
    /// The user hid an upgrade badge.
    case upgradeBadgeDismissed(source: String)
    /// The signed-in account's plan became paid. `upgradeSource` is the last
    /// upgrade click within the attribution window, or nil.
    case planActivated(upgradeSource: String?, sinceUpgradeClick: DurationBucket?)
    /// The signed-in account's plan went from paid to free.
    case planDeactivated

    // MARK: Sidebar Cloud button

    /// The sidebar footer Cloud button became visible. Deduplicated per launch.
    case cloudButtonShown
    /// The sidebar footer Cloud button was pressed.
    case cloudButtonClicked(action: CloudButtonAction)

    // MARK: Cloud welcome card

    /// The welcome card was shown.
    case cloudWelcomeShown(trigger: CloudWelcomeTrigger, step: CloudWelcomeStep)
    /// A button on the welcome card was clicked.
    case cloudWelcomeButtonClicked(trigger: CloudWelcomeTrigger, step: CloudWelcomeStep, button: CloudWelcomeButton)
    /// The welcome card closed, with how and after how long.
    case cloudWelcomeClosed(trigger: CloudWelcomeTrigger, step: CloudWelcomeStep, outcome: CloudWelcomeOutcome, visibleFor: DurationBucket)

    // MARK: Account

    case signInStarted
    case signInSucceeded
    case signInFailed(reason: SignInFailureReason)
    case signedOut

    // MARK: Cloud

    /// A Cloud enable attempt settled.
    case cloudEnableCompleted(result: CloudEnableResult)
    case cloudDisabled
    /// The New Machine sheet submitted a create. `memoryGB` is nil when the
    /// request sends no size (Base setup, forks).
    case cloudMachineCreateStarted(memoryGB: Int?)
    case cloudMachineCreateSucceeded(duration: DurationBucket)
    /// `consecutiveFailures` counts create failures since the last success.
    case cloudMachineCreateFailed(errorClass: CloudErrorClass, errorCode: String, consecutiveFailures: Int)
    case cloudMachineDeleted
    /// The attach endpoint request for a machine finished.
    case cloudMachineAttached(success: Bool, latency: DurationBucket, errorClass: CloudErrorClass?)
    case cloudWorkspaceCreated(machineChoice: CloudWorkspaceMachineChoice, duration: DurationBucket)
    /// A Cloud request was refused by a plan limit.
    case cloudPlanLimitHit(limit: CloudPlanLimit, operation: String)

    // MARK: Activation and engagement

    /// A first-time action. `isNewInstall` is false for installs that predate
    /// this catalog, whose real first use was never recorded.
    case activationMilestoneReached(milestone: ActivationMilestone, isNewInstall: Bool, daysSinceInstall: Int)
    case agentSessionStarted(agent: AgentKind)
    case agentSessionEnded(agent: AgentKind)
    /// A key surface was used. Deduplicated per feature per UTC day.
    case featureUsed(feature: ProductFeature)
    /// This launch runs a different version than the previous launch.
    case appUpdated(direction: AppUpdateDirection, fromVersion: String, toVersion: String)

    /// The PostHog event name.
    public var name: String {
        switch self {
        case .upgradePromptShown: "cmux_upgrade_prompt_shown"
        case .upgradeEntrypointOpened: "cmux_upgrade_entrypoint_opened"
        case .upgradeBadgeDismissed: "cmux_upgrade_badge_dismissed"
        case .planActivated: "cmux_plan_activated"
        case .planDeactivated: "cmux_plan_deactivated"
        case .cloudButtonShown: "cmux_cloud_button_shown"
        case .cloudButtonClicked: "cmux_cloud_button_clicked"
        case .cloudWelcomeShown: "cmux_cloud_welcome_shown"
        case .cloudWelcomeButtonClicked: "cmux_cloud_welcome_button_clicked"
        case .cloudWelcomeClosed: "cmux_cloud_welcome_closed"
        case .signInStarted: "cmux_sign_in_started"
        case .signInSucceeded: "cmux_sign_in_succeeded"
        case .signInFailed: "cmux_sign_in_failed"
        case .signedOut: "cmux_signed_out"
        case .cloudEnableCompleted: "cmux_cloud_enable_completed"
        case .cloudDisabled: "cmux_cloud_disabled"
        case .cloudMachineCreateStarted: "cmux_cloud_machine_create_started"
        case .cloudMachineCreateSucceeded: "cmux_cloud_machine_create_succeeded"
        case .cloudMachineCreateFailed: "cmux_cloud_machine_create_failed"
        case .cloudMachineDeleted: "cmux_cloud_machine_deleted"
        case .cloudMachineAttached: "cmux_cloud_machine_attached"
        case .cloudWorkspaceCreated: "cmux_cloud_workspace_created"
        case .cloudPlanLimitHit: "cmux_cloud_plan_limit_hit"
        case .activationMilestoneReached: "cmux_activation_milestone_reached"
        case .agentSessionStarted: "cmux_agent_session_started"
        case .agentSessionEnded: "cmux_agent_session_ended"
        case .featureUsed: "cmux_feature_used"
        case .appUpdated: "cmux_app_updated"
        }
    }

    /// The event-specific properties, before the shared context is merged.
    public var properties: [String: AnalyticsValue] {
        switch self {
        case let .upgradePromptShown(source, plan):
            return ["source": .string(Self.token(source)), "plan": .string(Self.token(plan))]
        case let .upgradeEntrypointOpened(source, plan, destination):
            // `source`, `client` and `plan` keep the keys this event had before
            // the catalog existed, so existing insights keep working.
            return [
                "source": .string(Self.token(source)),
                "client": .string("mac"),
                "plan": .string(Self.token(plan)),
                "destination": .string(destination.rawValue),
            ]
        case let .upgradeBadgeDismissed(source):
            return ["source": .string(Self.token(source))]
        case let .planActivated(upgradeSource, since):
            return [
                "upgrade_source": .string(upgradeSource.map(Self.token) ?? "none"),
                "since_upgrade_click": .string(since?.rawValue ?? "none"),
            ]
        case .planDeactivated, .signInStarted, .signInSucceeded, .signedOut, .cloudDisabled, .cloudMachineDeleted,
             .cloudButtonShown:
            return [:]
        case let .cloudButtonClicked(action):
            return ["action": .string(action.rawValue)]
        case let .cloudWelcomeShown(trigger, step):
            return ["trigger": .string(trigger.rawValue), "next_step": .string(step.rawValue)]
        case let .cloudWelcomeButtonClicked(trigger, step, button):
            return [
                "trigger": .string(trigger.rawValue),
                "next_step": .string(step.rawValue),
                "button": .string(button.rawValue),
            ]
        case let .cloudWelcomeClosed(trigger, step, outcome, visibleFor):
            return [
                "trigger": .string(trigger.rawValue),
                "next_step": .string(step.rawValue),
                "outcome": .string(outcome.rawValue),
                "visible_for": .string(visibleFor.rawValue),
            ]
        case let .signInFailed(reason):
            return ["reason": .string(reason.rawValue)]
        case let .cloudEnableCompleted(result):
            return ["result": .string(result.rawValue)]
        case let .cloudMachineCreateStarted(memoryGB):
            return memoryGB.map { ["memory_gb": .int($0)] } ?? [:]
        case let .cloudMachineCreateSucceeded(duration):
            return ["duration": .string(duration.rawValue)]
        case let .cloudMachineCreateFailed(errorClass, errorCode, consecutiveFailures):
            return [
                "error_class": .string(errorClass.rawValue),
                "error_code": .string(Self.token(errorCode)),
                "consecutive_failures": .int(consecutiveFailures),
            ]
        case let .cloudMachineAttached(success, latency, errorClass):
            var properties: [String: AnalyticsValue] = [
                "success": .bool(success),
                "latency": .string(latency.rawValue),
            ]
            if let errorClass { properties["error_class"] = .string(errorClass.rawValue) }
            return properties
        case let .cloudWorkspaceCreated(machineChoice, duration):
            return ["machine_choice": .string(machineChoice.rawValue), "duration": .string(duration.rawValue)]
        case let .cloudPlanLimitHit(limit, operation):
            return ["limit": .string(limit.rawValue), "operation": .string(Self.token(operation))]
        case let .activationMilestoneReached(milestone, isNewInstall, daysSinceInstall):
            return [
                "milestone": .string(milestone.rawValue),
                "is_new_install": .bool(isNewInstall),
                "days_since_install": .int(daysSinceInstall),
            ]
        case let .agentSessionStarted(agent), let .agentSessionEnded(agent):
            return ["agent": .string(agent.rawValue)]
        case let .featureUsed(feature):
            return ["feature": .string(feature.rawValue)]
        case let .appUpdated(direction, fromVersion, toVersion):
            return [
                "direction": .string(direction.rawValue),
                "from_version": .string(Self.version(fromVersion)),
                "to_version": .string(Self.version(toVersion)),
            ]
        }
    }

    /// Lowercase `[a-z0-9_]` tokens up to 64 characters pass; anything else
    /// becomes `other`, so a caller can never send free text by mistake.
    static func token(_ raw: String) -> String {
        let allowed = raw.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
        }
        return allowed && !raw.isEmpty && raw.utf8.count <= 64 ? raw : "other"
    }

    /// Dotted version strings (`0.65.2`) pass; anything else becomes `unknown`.
    static func version(_ raw: String) -> String {
        let allowed = raw.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
        }
        return allowed && !raw.isEmpty && raw.utf8.count <= 32 ? raw : "unknown"
    }
}
