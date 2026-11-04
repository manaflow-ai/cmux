import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxProductAnalytics

/// Pins every event name and property key. Renaming one breaks saved
/// insights; change this test, `docs/posthog/mac-product-analytics.md` and the insights
/// together.
@Suite("Product analytics event catalog")
struct ProductAnalyticsEventCatalogTests {
    static let attempt = SignInAttemptID(UUID(uuidString: "6F1C2A7E-0B5D-4C33-9E1A-2D4B8F00A1C9")!)

    static let catalog: [(ProductAnalyticsEvent, String, Set<String>)] = [
        (.upgradePromptShown(source: "mac_sidebar_badge", plan: "pro"), "cmux_upgrade_prompt_shown", ["source", "plan"]),
        (.upgradeEntrypointOpened(source: "mac_cloud_welcome", plan: "pro", destination: .pricingPage),
         "cmux_upgrade_entrypoint_opened", ["source", "client", "plan", "destination"]),
        (.upgradeBadgeDismissed(source: "mac_sidebar_badge"), "cmux_upgrade_badge_dismissed", ["source"]),
        (.planActivated(upgradeSource: "mac_sidebar_badge", sinceUpgradeClick: .from1to3m), "cmux_plan_activated",
         ["upgrade_source", "since_upgrade_click"]),
        (.planDeactivated, "cmux_plan_deactivated", []),
        (.cloudButtonShown, "cmux_cloud_button_shown", []),
        (.cloudButtonClicked(action: .introduceCloud), "cmux_cloud_button_clicked", ["action"]),
        (.cloudWelcomeShown(trigger: .launchAnnouncement, step: .upgrade), "cmux_cloud_welcome_shown", ["trigger", "next_step"]),
        (.cloudWelcomeButtonClicked(trigger: .newCloudMachine, step: .enable, button: .enable),
         "cmux_cloud_welcome_button_clicked", ["trigger", "next_step", "button"]),
        (.cloudWelcomeClosed(trigger: .newCloudWorkspace, step: .upgrade, outcome: .notNow, visibleFor: .from3to10s),
         "cmux_cloud_welcome_closed", ["trigger", "next_step", "outcome", "visible_for"]),
        (.signInStarted(entrypoint: .pane, start: .opened(attempt, replaced: nil)), "cmux_sign_in_started",
         ["attempt_id", "entrypoint", "start_outcome", "replaced_pending"]),
        (.signInStarted(entrypoint: .app, start: .opened(attempt, replaced: SignInAttemptID())), "cmux_sign_in_started",
         ["attempt_id", "entrypoint", "start_outcome", "replaced_pending", "replaced_attempt_id"]),
        (.signInStarted(entrypoint: .socket, start: .noAttempt(.alreadySignedIn)), "cmux_sign_in_started",
         ["entrypoint", "start_outcome", "replaced_pending"]),
        (.signInCallbackReceived(attemptID: attempt, delivery: .external, link: .state), "cmux_sign_in_callback_received",
         ["attempt_id", "delivery", "attempt_link"]),
        (.signInWindowClosed(attemptID: attempt), "cmux_sign_in_window_closed", ["attempt_id"]),
        (.signInSucceeded(attemptID: attempt, link: .state), "cmux_sign_in_succeeded", ["attempt_id", "attempt_link"]),
        (.signInFailed(reason: .timedOut, attemptID: attempt), "cmux_sign_in_failed", ["reason", "attempt_id"]),
        (.signedOut, "cmux_signed_out", []),
        (.cloudEnableCompleted(result: .success), "cmux_cloud_enable_completed", ["result"]),
        (.cloudDisabled, "cmux_cloud_disabled", []),
        (.cloudMachineCreateStarted(memoryGB: 8), "cmux_cloud_machine_create_started", ["memory_gb"]),
        (.cloudMachineCreateStarted(memoryGB: nil), "cmux_cloud_machine_create_started", []),
        (.cloudMachineCreateSucceeded(duration: .from10to30s), "cmux_cloud_machine_create_succeeded", ["duration"]),
        (.cloudMachineCreateFailed(errorClass: .server, errorCode: "http_500", consecutiveFailures: 2),
         "cmux_cloud_machine_create_failed", ["error_class", "error_code", "consecutive_failures"]),
        (.cloudMachineDeleted, "cmux_cloud_machine_deleted", []),
        (.cloudMachineAttached(success: false, latency: .from1to3s, errorClass: .network),
         "cmux_cloud_machine_attached", ["success", "latency", "error_class"]),
        (.cloudWorkspaceCreated(machineChoice: .resolved, duration: .from3to10s), "cmux_cloud_workspace_created",
         ["machine_choice", "duration"]),
        (.cloudPlanLimitHit(limit: .activeMachines, operation: "create"), "cmux_cloud_plan_limit_hit", ["limit", "operation"]),
        (.activationMilestoneReached(milestone: .firstSplit, isNewInstall: true, daysSinceInstall: 0),
         "cmux_activation_milestone_reached", ["milestone", "is_new_install", "days_since_install"]),
        (.agentSessionStarted(agent: .codex), "cmux_agent_session_started", ["agent"]),
        (.agentSessionEnded(agent: .claudeCode), "cmux_agent_session_ended", ["agent"]),
        (.featureUsed(feature: .commandPalette), "cmux_feature_used", ["feature"]),
        (.appUpdated(direction: .upgrade, fromVersion: "0.65.1", toVersion: "0.65.2"), "cmux_app_updated",
         ["direction", "from_version", "to_version"]),
    ]

    @Test("every event has its pinned name and property keys")
    func pinnedNamesAndKeys() {
        for (event, name, keys) in Self.catalog {
            #expect(event.name == name)
            #expect(Set(event.properties.keys) == keys, "\(name)")
        }
    }

    @Test("names are unique, snake_case and cmux_ prefixed")
    func namingConvention() {
        let names = Set(Self.catalog.map(\.1))
        #expect(names.count == 30)
        for name in names {
            #expect(name.hasPrefix("cmux_"))
            #expect(name.allSatisfy { $0.isLowercase || $0 == "_" })
        }
    }

    @Test("the shared context keys are pinned and never collide with event keys")
    func contextKeys() {
        let context = ProductAnalyticsContext(appVersion: "0.65.2", appBuild: "1", channel: "nightly", osVersion: "15.5")
        #expect(Set(context.properties.keys) == [
            "app_version", "app_build", "channel", "os_version",
            "account_plan", "is_signed_in", "cloud_enabled", "workspaces_open",
        ])
        for (event, name, _) in Self.catalog {
            #expect(Set(event.properties.keys).isDisjoint(with: context.properties.keys), "\(name)")
        }
    }

    @Test("free text cannot reach a token property")
    func tokensRejectFreeText() {
        let event = ProductAnalyticsEvent.cloudMachineCreateFailed(
            errorClass: .client,
            errorCode: "Machine my-host.example.com failed: /Users/me",
            consecutiveFailures: 1
        )
        #expect(event.properties["error_code"] == .string("other"))
        let upgrade = ProductAnalyticsEvent.upgradePromptShown(source: "user@example.com", plan: "pro")
        #expect(upgrade.properties["source"] == .string("other"))
        let update = ProductAnalyticsEvent.appUpdated(direction: .upgrade, fromVersion: "/tmp/x", toVersion: "0.65.2")
        #expect(update.properties["from_version"] == .string("unknown"))
    }

    @Test("agent sources map to a closed set")
    func agentKinds() {
        #expect(AgentKind(hookSource: "claude") == .claudeCode)
        #expect(AgentKind(hookSource: "codex") == .codex)
        #expect(AgentKind(hookSource: "opencode") == .opencode)
        #expect(AgentKind(hookSource: "cmux-pi-extension") == .pi)
        #expect(AgentKind(hookSource: "my secret agent") == .other)
    }

    @Test("Cloud error codes classify without the raw message")
    func errorClasses() {
        #expect(CloudErrorClass(errorCode: "vm_active_limit_exceeded") == .planLimit)
        #expect(CloudErrorClass(errorCode: "not_signed_in") == .auth)
        #expect(CloudErrorClass(errorCode: "backend_unreachable") == .network)
        #expect(CloudErrorClass(errorCode: "http_503") == .server)
        #expect(CloudErrorClass(errorCode: "vm_not_found") == .client)
        #expect(CloudPlanLimit(errorCode: "vm_memory_requires_plan") == .machineMemory)
        #expect(CloudPlanLimit(errorCode: "vm_not_found") == nil)
    }

    @Test("durations bucket at their boundaries")
    func durationBuckets() {
        #expect(DurationBucket(seconds: -1) == .under1s)
        #expect(DurationBucket(seconds: 0.999) == .under1s)
        #expect(DurationBucket(seconds: 1) == .from1to3s)
        #expect(DurationBucket(seconds: 59) == .from30to60s)
        #expect(DurationBucket(seconds: 7 * 86_400) == .over7d)
    }

    @Test("sign-in events carry only bounded values and a random attempt UUID")
    func signInPropertiesAreBounded() {
        let attempt = SignInAttemptID()
        let events: [ProductAnalyticsEvent] =
            SignInEntrypoint.allCases.flatMap { entrypoint -> [ProductAnalyticsEvent] in
                let starts: [SignInStart] = [.opened(attempt, replaced: nil), .opened(attempt, replaced: attempt)]
                    + SignInStartOutcome.allCases.filter { $0 != .opened }.map { .noAttempt($0) }
                return starts.map { .signInStarted(entrypoint: entrypoint, start: $0) }
            }
            + SignInCallbackDelivery.allCases.flatMap { delivery in
                SignInAttemptLink.allCases.map { .signInCallbackReceived(attemptID: attempt, delivery: delivery, link: $0) }
            }
            + SignInFailureReason.allCases.map { .signInFailed(reason: $0, attemptID: attempt) }
            + SignInAttemptLink.allCases.map { .signInSucceeded(attemptID: attempt, link: $0) }
            + [.signInWindowClosed(attemptID: attempt)]
        let bounded = Set(SignInEntrypoint.allCases.map(\.rawValue))
            .union(SignInCallbackDelivery.allCases.map(\.rawValue))
            .union(SignInFailureReason.allCases.map(\.rawValue))
            .union(SignInAttemptLink.allCases.map(\.rawValue))
            .union(SignInStartOutcome.allCases.map(\.rawValue))
        for event in events {
            for (key, value) in event.properties {
                switch (key, value) {
                case let ("attempt_id", .string(id)), let ("replaced_attempt_id", .string(id)):
                    #expect(id == attempt.token)
                    #expect(UUID(uuidString: id) != nil && id == id.lowercased(), "\(event.name)")
                case ("replaced_pending", .bool):
                    break
                case let (_, .string(token)):
                    #expect(bounded.contains(token), "\(event.name).\(key) = \(token)")
                default:
                    Issue.record("\(event.name).\(key) has an unexpected value type")
                }
            }
        }
        #expect(SignInAttemptID().token != SignInAttemptID().token)
    }
}
