import CMUXMobileCore
import Foundation
import os
import Testing

@testable import CmuxProductAnalytics

/// A clock tests can move.
final class TestClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { state.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { state.withLock { $0 += seconds } }
}

@Suite("Product analytics pipeline")
struct ProductAnalyticsPipelineTests {
    /// A class so the suite it created is removed when the test drops it.
    final class Harness {
        let sink: RecordingAnalyticsSink
        let clock: TestClock
        let defaults: UserDefaults
        let analytics: ProductAnalytics
        private let ownedSuiteName: String?

        init(
            enabled: Bool = true,
            preexisting: Bool = false,
            version: String = "0.66.0",
            defaults: UserDefaults? = nil
        ) {
            let suiteName = defaults == nil ? "product-analytics-\(UUID().uuidString)" : nil
            let defaults = defaults ?? UserDefaults(suiteName: suiteName)!
            ownedSuiteName = suiteName
            let sink = RecordingAnalyticsSink()
            let clock = TestClock()
            self.defaults = defaults
            self.sink = sink
            self.clock = clock
            analytics = ProductAnalytics(
                isEnabled: enabled,
                sink: sink,
                ledger: ProductAnalyticsLedger(defaults: defaults),
                context: ProductAnalyticsContext(appVersion: version, appBuild: "100", channel: "dev", osVersion: "15.5"),
                isPreexistingInstall: preexisting,
                now: { clock.now }
            )
        }

        deinit {
            if let ownedSuiteName { defaults.removePersistentDomain(forName: ownedSuiteName) }
        }

        func milestones() -> [String] {
            sink.events.filter { $0.name == "cmux_activation_milestone_reached" }.compactMap {
                if case let .string(value)? = $0.properties["milestone"] { return value }
                return nil
            }
        }
    }

    @Test("opt-out sends nothing at all")
    func optOutStopsAllCapture() async {
        let harness = Harness(enabled: false)
        harness.analytics.track(.signInStarted)
        harness.analytics.track(.upgradeEntrypointOpened(source: "mac_sidebar_badge", plan: "pro", destination: .pricingPage))
        harness.analytics.featureUsed(.commandPalette)
        harness.analytics.identify(userID: "user-1")
        harness.analytics.notePlan(accountID: "user-1", isPaid: true)
        harness.analytics.noteAgentHook(source: "codex", sessionID: "s", phase: .sessionStart)
        harness.analytics.signedOut()
        await harness.analytics.drain()
        #expect(harness.sink.calls.isEmpty)
        #expect(ProductAnalytics.disabled.isEnabled == false)
    }

    @Test("events carry the shared context; event keys win")
    func contextMerged() async throws {
        let harness = Harness()
        harness.analytics.updateContext(.cloudEnabled(true))
        harness.analytics.updateContext(.plan(.free))
        harness.analytics.track(.upgradePromptShown(source: "mac_sidebar_badge", plan: "pro"))
        await harness.analytics.drain()
        let event = try #require(harness.sink.events.first { $0.name == "cmux_upgrade_prompt_shown" })
        #expect(event.properties["source"] == .string("mac_sidebar_badge"))
        #expect(event.properties["plan"] == .string("pro"))
        #expect(event.properties["account_plan"] == .string("free"))
        #expect(event.properties["cloud_enabled"] == .bool(true))
        #expect(event.properties["channel"] == .string("dev"))
        #expect(event.properties["app_version"] == .string("0.66.0"))
    }

    @Test("a new install reports first launch once; a pre-catalog install never does")
    func firstLaunch() async {
        let fresh = Harness()
        await fresh.analytics.drain()
        #expect(fresh.milestones() == ["first_launch"])

        let relaunch = Harness(defaults: fresh.defaults)
        await relaunch.analytics.drain()
        #expect(relaunch.milestones().isEmpty)

        withExtendedLifetime(fresh) {}

        let existing = Harness(preexisting: true)
        existing.analytics.featureUsed(.split)
        await existing.analytics.drain()
        #expect(existing.milestones() == ["first_split"])
        let milestone = existing.sink.events.first { $0.name == "cmux_activation_milestone_reached" }
        #expect(milestone?.properties["is_new_install"] == .bool(false))
    }

    @Test("upgrade prompts dedupe per source per launch; clicks never dedupe")
    func impressionsDedupe() async {
        let harness = Harness()
        for _ in 0..<3 {
            harness.analytics.track(.upgradePromptShown(source: "mac_sidebar_badge", plan: "pro"))
            harness.analytics.track(.upgradeEntrypointOpened(source: "mac_sidebar_badge", plan: "pro", destination: .pricingPage))
        }
        harness.analytics.track(.upgradePromptShown(source: "mac_cloud_welcome", plan: "pro"))
        harness.analytics.track(.cloudButtonShown)
        harness.analytics.track(.cloudButtonShown)
        await harness.analytics.drain()
        let names = harness.sink.eventNames
        #expect(names.filter { $0 == "cmux_upgrade_prompt_shown" }.count == 2)
        #expect(names.filter { $0 == "cmux_cloud_button_shown" }.count == 1)
        #expect(names.filter { $0 == "cmux_upgrade_entrypoint_opened" }.count == 3)
        #expect(harness.milestones() == ["first_launch", "first_upgrade_click"])
    }

    @Test("features count once per UTC day")
    func featureDailyDedupe() async {
        let harness = Harness()
        harness.analytics.featureUsed(.commandPalette)
        harness.analytics.featureUsed(.commandPalette)
        await harness.analytics.drain()
        harness.clock.advance(86_400)
        harness.analytics.featureUsed(.commandPalette)
        await harness.analytics.drain()
        #expect(harness.sink.eventNames.filter { $0 == "cmux_feature_used" }.count == 2)
    }

    @Test("a paid plan after an upgrade click is attributed to that click's source")
    func planActivationAttribution() async throws {
        let harness = Harness()
        harness.analytics.identify(userID: "user-1")
        harness.analytics.notePlan(accountID: "user-1", isPaid: false)
        harness.analytics.track(.upgradeEntrypointOpened(source: "mac_cloud_welcome", plan: "pro", destination: .pricingPage))
        await harness.analytics.drain()
        harness.clock.advance(120)
        harness.analytics.notePlan(accountID: "user-1", isPaid: true)
        harness.analytics.notePlan(accountID: "user-1", isPaid: true)
        await harness.analytics.drain()
        let activated = harness.sink.events.filter { $0.name == "cmux_plan_activated" }
        #expect(activated.count == 1)
        let event = try #require(activated.first)
        #expect(event.properties["upgrade_source"] == .string("mac_cloud_welcome"))
        #expect(event.properties["since_upgrade_click"] == .string("1m_3m"))
        #expect(event.properties["account_plan"] == .string("paid"))
        #expect(harness.milestones().contains("first_paid_plan"))

        harness.analytics.notePlan(accountID: "user-1", isPaid: false)
        await harness.analytics.drain()
        #expect(harness.sink.eventNames.last == "cmux_plan_deactivated")
    }

    @Test("a click attributes one activation, and only for the account that clicked")
    func attributionIsPerAccountAndSingleUse() async {
        let harness = Harness()
        harness.analytics.identify(userID: "user-a")
        harness.analytics.notePlan(accountID: "user-a", isPaid: false)
        harness.analytics.track(.upgradeEntrypointOpened(source: "mac_sidebar_badge", plan: "pro", destination: .pricingPage))
        // Switching to an already-paid account is not an activation from A's click.
        harness.analytics.signedOut()
        harness.analytics.identify(userID: "user-b")
        harness.analytics.notePlan(accountID: "user-b", isPaid: true)
        await harness.analytics.drain()
        #expect(!harness.sink.eventNames.contains("cmux_plan_activated"))

        harness.analytics.signedOut()
        harness.analytics.identify(userID: "user-a")
        harness.analytics.notePlan(accountID: "user-a", isPaid: true)
        harness.analytics.notePlan(accountID: "user-a", isPaid: false)
        harness.analytics.notePlan(accountID: "user-a", isPaid: true)
        await harness.analytics.drain()
        let activations = harness.sink.events.filter { $0.name == "cmux_plan_activated" }
        #expect(activations.map { $0.properties["upgrade_source"] } == [.string("mac_sidebar_badge"), .string("none")])
    }

    @Test("an existing subscriber seen for the first time is not an activation")
    func existingSubscriber() async {
        let harness = Harness()
        harness.analytics.notePlan(accountID: "user-1", isPaid: true)
        await harness.analytics.drain()
        #expect(!harness.sink.eventNames.contains("cmux_plan_activated"))
    }

    @Test("identify once per user, and sign out after the event")
    func identityLifecycle() async {
        let harness = Harness()
        harness.analytics.identify(userID: "user-1")
        harness.analytics.identify(userID: "user-1")
        harness.analytics.signedOut()
        harness.analytics.signedOut()
        await harness.analytics.drain()
        let identity: [String] = harness.sink.calls.compactMap {
            switch $0 {
            case let .identify(user): return "identify:\(user ?? "nil")"
            case let .capture(name, _): return name == "cmux_signed_out" ? name : nil
            case .superProperties: return nil
            }
        }
        #expect(identity == ["identify:user-1", "cmux_signed_out", "identify:nil"])
        let signedOut = harness.sink.events.first { $0.name == "cmux_signed_out" }
        #expect(signedOut?.properties["is_signed_in"] == .bool(true))
    }

    @Test("agent sessions start once, end once, and never send the session id")
    func agentSessions() async {
        let harness = Harness()
        harness.analytics.noteAgentHook(source: "claude", sessionID: "secret-session", phase: .sessionStart)
        harness.analytics.noteAgentHook(source: "claude", sessionID: "secret-session", phase: .activity)
        // A session first seen mid-flight (it outlived a relaunch) is neither
        // started nor ended again.
        harness.analytics.noteAgentHook(source: "codex", sessionID: "other", phase: .activity)
        harness.analytics.noteAgentHook(source: "codex", sessionID: "other", phase: .sessionEnd)
        harness.analytics.noteAgentHook(source: "claude", sessionID: "secret-session", phase: .sessionEnd)
        harness.analytics.noteAgentHook(source: "claude", sessionID: "secret-session", phase: .sessionEnd)
        await harness.analytics.drain()
        let names = harness.sink.eventNames
        #expect(names.filter { $0 == "cmux_agent_session_started" }.count == 1)
        #expect(names.filter { $0 == "cmux_agent_session_ended" }.count == 1)
        #expect(harness.milestones().contains("first_agent_session"))
        for event in harness.sink.events {
            #expect(!event.properties.values.contains(.string("secret-session")))
        }
    }

    @Test("Cloud requests become delete, attach and plan-limit events; creates count once")
    func cloudRequests() async {
        let harness = Harness()
        let analytics = harness.analytics
        // A create's own request is skipped: the create coordinator reports it.
        analytics.noteCloudRequest(.init(method: "POST", route: "/api/vm", success: false, errorCode: "vm_active_limit_exceeded", durationMs: 300))
        analytics.noteCloudRequest(.init(method: "GET", route: "/api/vm/{id}/attach-endpoint", success: true, errorCode: nil, durationMs: 450))
        analytics.noteCloudRequest(.init(method: "GET", route: "/api/vm/{id}/attach-endpoint", success: false, errorCode: "backend_unreachable", durationMs: 4_000))
        analytics.noteCloudRequest(.init(method: "DELETE", route: "/api/vm/{id}", success: true, errorCode: nil, durationMs: 800))
        analytics.noteCloudRequest(.init(method: "POST", route: "/api/vm/{id}/resize", success: false, errorCode: "vm_resize_plan_limit", durationMs: 100))
        analytics.noteCloudRequest(.init(method: "GET", route: "/api/vm", success: false, errorCode: "cancelled", durationMs: 1))
        await analytics.drain()
        let events = harness.sink.events.filter { $0.name != "cmux_activation_milestone_reached" }
        #expect(events.map(\.name) == [
            "cmux_cloud_machine_attached",
            "cmux_cloud_machine_attached",
            "cmux_cloud_machine_deleted",
            "cmux_cloud_plan_limit_hit",
        ])
        #expect(events[0].properties["latency"] == .string("lt_1s"))
        #expect(events[1].properties["success"] == .bool(false))
        #expect(events[1].properties["error_class"] == .string("network"))
        #expect(events[3].properties["limit"] == .string("resize_size"))
        #expect(events[3].properties["operation"] == .string("resize"))
    }

    @Test("machine creates report outcome, consecutive failures and the plan limit")
    func machineCreates() async {
        let harness = Harness()
        let analytics = harness.analytics
        analytics.noteMachineCreateFinished(succeeded: false, errorCode: nil, seconds: 2)
        analytics.noteMachineCreateFinished(succeeded: false, errorCode: "vm_active_limit_exceeded", seconds: 0.3)
        analytics.noteMachineCreateFinished(succeeded: true, errorCode: nil, seconds: 14)
        await analytics.drain()
        let events = harness.sink.events.filter { $0.name != "cmux_activation_milestone_reached" }
        #expect(events.map(\.name) == [
            "cmux_cloud_machine_create_failed",
            "cmux_cloud_machine_create_failed",
            "cmux_cloud_plan_limit_hit",
            "cmux_cloud_machine_create_succeeded",
        ])
        #expect(events[0].properties["error_class"] == .string("server"))
        #expect(events[1].properties["consecutive_failures"] == .int(2))
        #expect(events[1].properties["error_class"] == .string("plan_limit"))
        #expect(events[2].properties["limit"] == .string("active_machines"))
        #expect(events[2].properties["operation"] == .string("create"))
        #expect(events[3].properties["duration"] == .string("10s_30s"))
        #expect(harness.milestones().contains("first_cloud_machine"))
    }

    @Test("a version change reports its direction")
    func appUpdated() async {
        let first = Harness(version: "0.65.2")
        await first.analytics.drain()
        let upgraded = Harness(version: "0.66.0", defaults: first.defaults)
        await upgraded.analytics.drain()
        let downgraded = Harness(version: "0.65.2", defaults: first.defaults)
        await downgraded.analytics.drain()
        #expect(upgraded.sink.events.first { $0.name == "cmux_app_updated" }?.properties["direction"] == .string("upgrade"))
        #expect(downgraded.sink.events.first { $0.name == "cmux_app_updated" }?.properties["direction"] == .string("downgrade"))
        #expect(!first.sink.eventNames.contains("cmux_app_updated"))
        withExtendedLifetime(first) {}
    }
}
