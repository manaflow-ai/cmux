import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileNotifications

/// Agent Alarms: which events ring, the one 30 second window across every source, one alarm
/// per event, and what AlarmKit's refusals leave behind.
@Suite struct AgentAlarmTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let on = AgentAlarmPreferences(enabled: true)

    // MARK: Triggers

    @Test func pushKindsMapToTriggers() {
        func trigger(_ kind: PushKind, _ state: PushPayload.State? = nil) -> AgentAlarmTrigger? {
            AgentAlarmTrigger(payload: PushPayload(mac: "m", kind: kind, state: state))
        }
        #expect(trigger(.permission) == .permission)
        #expect(trigger(.question) == .question)
        #expect(trigger(.failed) == .agentFailed)
        #expect(trigger(.terminal, .waiting) == .needsInput)
        #expect(trigger(.terminal, .failed) == .agentFailed)
        // Never: a finished turn, Chief, a plain terminal notification.
        #expect(trigger(.completed) == nil)
        #expect(trigger(.chief) == nil)
        #expect(trigger(.terminal, .finished) == nil)
        #expect(trigger(.terminal, .notified) == nil)
        #expect(trigger(.terminal) == nil)
    }

    @Test func defaultsAreOffWithEveryTriggerButMacOffline() {
        let fresh = AgentAlarmPreferences()
        #expect(!fresh.enabled)
        #expect(fresh.triggers == [.permission, .question, .needsInput, .agentFailed])
        #expect(!fresh.rings(.permission))
        #expect(on.rings(.permission))
        #expect(!on.rings(.macOffline))
    }

    @Test func titlesNameTheAgentOrTheMac() {
        #expect(AgentAlarmTrigger.permission.alarmTitle(agent: "Claude Code") == "Claude Code needs permission")
        #expect(AgentAlarmTrigger.question.alarmTitle(agent: nil) == "Your agent has a question")
        #expect(AgentAlarmTrigger.agentFailed.alarmTitle(agent: "") == "Your agent stopped")
        #expect(AgentAlarmTrigger.macOffline.alarmTitle(agent: "Mac mini") == "Mac mini went offline")
        #expect(AgentAlarmTrigger.macOffline.alarmTitle(agent: nil) == "Your Mac went offline")
    }

    @Test func aPushAndItsFeedRowShareOneKey() {
        let push = PushPayload(mac: "m", kind: .permission, eventId: "e1", permissionId: "p1")
        #expect(AgentAlarmGate.key(push) == "ask:p1")
        #expect(AgentAlarmGate.key(PushPayload(mac: "m", kind: .failed, eventId: "e2")) == "event:e2")
        #expect(AgentAlarmGate.key(PushPayload(mac: "m", kind: .failed, notificationId: "n3")) == "other:n3")
        #expect(AgentAlarmGate.key(PushPayload(mac: "m", kind: .failed)) == nil)
    }

    // MARK: The gate

    @Test func offOrTriggerOffNeverRings() {
        var ledger = AgentAlarmLedger()
        #expect(AgentAlarmGate.claim(.permission, key: "a", now: t0, preferences: AgentAlarmPreferences(), ledger: &ledger) == .off)
        var some = on
        some.triggers.remove(.question)
        #expect(AgentAlarmGate.claim(.question, key: "b", now: t0, preferences: some, ledger: &ledger) == .triggerOff)
        // Neither is recorded: turning it on later still rings for a new event.
        #expect(ledger.lastRang == nil)
        #expect(ledger.seen.isEmpty)
    }

    @Test func noTwoAlarmsWithinThirtySeconds() {
        var ledger = AgentAlarmLedger()
        #expect(AgentAlarmGate.claim(.permission, key: "a", now: t0, preferences: on, ledger: &ledger) == .ring)
        // Any trigger, any event: held for the rest of the window.
        #expect(AgentAlarmGate.claim(.question, key: "b", now: t0.addingTimeInterval(1), preferences: on, ledger: &ledger)
            == .debounced(wait: 29))
        #expect(AgentAlarmGate.claim(.agentFailed, key: "c", now: t0.addingTimeInterval(29.9), preferences: on, ledger: &ledger).rings == false)
        // Exactly 30 s later: rings.
        #expect(AgentAlarmGate.claim(.needsInput, key: "d", now: t0.addingTimeInterval(30), preferences: on, ledger: &ledger) == .ring)
        #expect(ledger.lastRang == t0.addingTimeInterval(30))
    }

    @Test func aHeldEventNeverRingsLate() {
        var ledger = AgentAlarmLedger()
        _ = AgentAlarmGate.claim(.permission, key: "a", now: t0, preferences: on, ledger: &ledger)
        _ = AgentAlarmGate.claim(.question, key: "b", now: t0.addingTimeInterval(5), preferences: on, ledger: &ledger)
        // The same question again (its Feed row after its push), after the window: already handled.
        #expect(AgentAlarmGate.claim(.question, key: "b", now: t0.addingTimeInterval(60), preferences: on, ledger: &ledger) == .duplicate)
    }

    @Test func oneAlarmPerEvent() {
        var ledger = AgentAlarmLedger()
        #expect(AgentAlarmGate.claim(.permission, key: "ask:p1", now: t0, preferences: on, ledger: &ledger) == .ring)
        #expect(AgentAlarmGate.claim(.permission, key: "ask:p1", now: t0.addingTimeInterval(120), preferences: on, ledger: &ledger) == .duplicate)
        // A day later the key is forgotten (pruned).
        #expect(AgentAlarmGate.claim(.permission, key: "ask:p1", now: t0.addingTimeInterval(25 * 3600), preferences: on, ledger: &ledger) == .ring)
    }

    @Test func aClockMovedBackHoldsInsteadOfRingingTwice() {
        var ledger = AgentAlarmLedger(lastRang: t0)
        #expect(AgentAlarmGate.claim(.permission, key: "a", now: t0.addingTimeInterval(-600), preferences: on, ledger: &ledger)
            == .debounced(wait: 30))
    }

    @Test func debounceRemainingCountsDown() {
        let ledger = AgentAlarmLedger(lastRang: t0)
        #expect(ledger.debounceRemaining(now: t0.addingTimeInterval(12)) == 18)
        #expect(ledger.debounceRemaining(now: t0.addingTimeInterval(30)) == nil)
        #expect(AgentAlarmLedger().debounceRemaining(now: t0) == nil)
    }

    // MARK: The shared store

    @Test func theStoreKeepsPreferencesAndTheWindowForBothProcesses() {
        let memory = PushMemoryStore()
        let app = AgentAlarmStore(keychain: memory, defaults: nil)
        let serviceExtension = AgentAlarmStore(keychain: memory, defaults: nil)
        #expect(app.sharedWithExtension)
        app.save(AgentAlarmPreferences(enabled: true, triggers: [.permission, .agentFailed]))
        #expect(serviceExtension.preferences() == AgentAlarmPreferences(enabled: true, triggers: [.permission, .agentFailed]))
        // The extension rings; the app, 10 s later, is held by the same window.
        #expect(serviceExtension.claim(.permission, key: "ask:p1", source: .serviceExtension, title: "x", now: t0) == .ring)
        #expect(app.claim(.agentFailed, key: "event:e1", source: .feed, title: "y", now: t0.addingTimeInterval(10)) == .debounced(wait: 20))
        // And its Feed row of the extension's ask is a duplicate.
        #expect(app.claim(.permission, key: "ask:p1", source: .feed, title: "x", now: t0.addingTimeInterval(40)) == .duplicate)
        let history = app.ledger().history
        #expect(history.map(\.outcome) == [.debounced, .rang])
        #expect(history.map(\.source) == [.feed, .serviceExtension])
        #expect(history.first?.wait == 20)
    }

    @Test func historyKeepsTheNewestTwenty() {
        let store = AgentAlarmStore(keychain: PushMemoryStore(), defaults: nil)
        store.save(on)
        for i in 0..<30 {
            _ = store.claim(.permission, key: "k\(i)", source: .test, title: "\(i)", now: t0.addingTimeInterval(Double(i) * 31))
        }
        let history = store.ledger().history
        #expect(history.count == 20)
        #expect(history.first?.title == "29")
        store.resetLedger()
        #expect(store.ledger() == AgentAlarmLedger())
    }

    @Test func aBuildWithoutTheKeychainGroupKeepsItInDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentAlarmTests-\(UUID().uuidString)"))
        let store = AgentAlarmStore(keychain: nil, defaults: defaults)
        #expect(!store.sharedWithExtension)
        store.save(on)
        #expect(AgentAlarmStore(keychain: nil, defaults: defaults).preferences() == on)
    }

    // MARK: AlarmKit

    @Test func ringsThroughAlarmKitAndStopsWhenTheAskCloses() async {
        let store = AgentAlarmStore(keychain: PushMemoryStore(), defaults: nil)
        store.save(on)
        let ringer = FakeRinger(.authorized)
        let push = PushPayload(mac: "m", kind: .permission, agent: "Claude Code", permissionId: "p1")
        let outcome = await AgentAlarms.handle(push, source: .serviceExtension, store: store, ringer: ringer)
        #expect(outcome?.rang == true)
        #expect(ringer.rung == ["Claude Code needs permission"])
        AgentAlarms.closed(keys: ["ask:p1"], store: store, ringer: ringer)
        #expect(ringer.stopped.count == 1)
        // Closed once: a second close stops nothing.
        AgentAlarms.closed(keys: ["ask:p1"], store: store, ringer: ringer)
        #expect(ringer.stopped.count == 1)
    }

    @Test func pushesThatNeverRingAreSkippedBeforeTheGate() async {
        let store = AgentAlarmStore(keychain: PushMemoryStore(), defaults: nil)
        store.save(on)
        let ringer = FakeRinger(.authorized)
        #expect(await AgentAlarms.handle(PushPayload(mac: "m", kind: .completed, eventId: "e"), source: .foregroundPush,
                                         store: store, ringer: ringer) == nil)
        #expect(ringer.rung.isEmpty)
        #expect(store.ledger().lastRang == nil)
    }

    @Test func withoutAlarmPermissionNothingRingsAndRecentSaysWhy() async {
        for state in [AgentAlarmAuthorization.denied, .notDetermined, .unavailable] {
            let store = AgentAlarmStore(keychain: PushMemoryStore(), defaults: nil)
            store.save(on)
            let ringer = FakeRinger(state)
            let outcome = await AgentAlarms.handle(.question, key: "ask:q", agent: "Codex", source: .feed, store: store,
                                                   ringer: ringer, now: t0)
            #expect(outcome == .notAllowed(state))
            #expect(ringer.rung.isEmpty)
            #expect(store.ledger().history.first?.outcome == .notAllowed)
        }
    }

    @Test func testAlarmRingsEvenWithItsTriggerOff() async {
        let store = AgentAlarmStore(keychain: PushMemoryStore(), defaults: nil)
        store.save(AgentAlarmPreferences(enabled: true, triggers: []))
        let ringer = FakeRinger(.authorized)
        #expect(await AgentAlarms.handle(.permission, key: "test:1", agent: nil, source: .test, store: store, ringer: ringer,
                                         overrideTrigger: true, now: t0).rang)
        // But still not with Agent Alarms off.
        store.save(AgentAlarmPreferences(enabled: false))
        #expect(await AgentAlarms.handle(.permission, key: "test:2", agent: nil, source: .test, store: store, ringer: ringer,
                                         overrideTrigger: true, now: t0.addingTimeInterval(60)) == .skipped(.off))
    }

    // MARK: Which delivered notifications may ring

    @Test func onlyAnOpenedUnmutedPushRings() {
        let service = ServicePush()
        func content(_ category: PushCategory, _ payload: PushPayload?) -> UNNotificationContent {
            let content = UNMutableNotificationContent()
            content.categoryIdentifier = category.rawValue
            if let payload { content.userInfo = payload.userInfo }
            return content
        }
        let ask = PushPayload(mac: "m", kind: .permission, permissionId: "p")
        #expect(service.alarmPayload(content(.permission, ask), muted: false) == ask)
        // Withheld, inert, stale or unopened: the sealed category, never rings.
        #expect(service.alarmPayload(content(.sealed, ask), muted: false) == nil)
        // A muted chat arrives quietly and doesn't ring.
        #expect(service.alarmPayload(content(.permission, ask), muted: true) == nil)
        // A finished turn doesn't ring; nor does a notification with no payload.
        #expect(service.alarmPayload(content(.completed, PushPayload(mac: "m", kind: .completed)), muted: false) == nil)
        #expect(service.alarmPayload(content(.permission, nil), muted: false) == nil)
    }
}

/// AlarmKit stand-in.
private final class FakeRinger: AgentAlarmRinging, @unchecked Sendable { // crash-allow: tests run it on one task
    let state: AgentAlarmAuthorization
    var rung: [String] = []
    var stopped: [UUID] = []

    init(_ state: AgentAlarmAuthorization) { self.state = state }

    func authorization() -> AgentAlarmAuthorization { state }
    func requestAuthorization() async -> AgentAlarmAuthorization { state }
    func ring(title: String, trigger: AgentAlarmTrigger, key: String) async throws -> UUID {
        rung.append(title)
        return UUID()
    }
    func stop(_ id: UUID) { stopped.append(id) }
}
