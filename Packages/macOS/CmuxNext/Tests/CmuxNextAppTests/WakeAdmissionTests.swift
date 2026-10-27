import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// p07-memory-105: wakes nobody asked for (an agent's or a script's call on a hibernated tab, a neighbor or
/// hover prewarm) are admitted as Chrome admits background tab loads
/// (chrome/browser/performance_manager/policies/background_tab_loading_policy.cc): at most
/// clamp(cores / 2, 1, 4) restore at once, the waiting ones are dropped at warning pressure with a typed
/// deferral, none starts under 150 MB free, and a person's show is never queued.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct WakeAdmissionTests {
    private static let plenty: UInt64 = 8 << 30

    private static func admission(cores: Int = 8, free: UInt64? = plenty) -> WakeAdmission {
        WakeAdmission(isEnabled: true, cores: cores, freeBytes: { free })
    }

    // MARK: The slot count

    @Test func theLimitIsHalfTheCoresClampedToOneThroughFour() {
        #expect(WakeAdmission.limit(cores: 0) == 1)
        #expect(WakeAdmission.limit(cores: 1) == 1)
        #expect(WakeAdmission.limit(cores: 2) == 1)
        #expect(WakeAdmission.limit(cores: 4) == 2)
        #expect(WakeAdmission.limit(cores: 6) == 3)
        #expect(WakeAdmission.limit(cores: 8) == 4)
        #expect(WakeAdmission.limit(cores: 24) == 4)
    }

    @Test func tenAgentWakesOnEightCoresStartFourAndTheRestWaitInOrder() {
        let admission = Self.admission(cores: 8)
        let keys = (0 ..< 10).map { "tab\($0)" }
        let outcomes = keys.map { admission.request($0, by: .automation, pressure: .normal) }
        #expect(outcomes.filter { $0 == .started }.count == 4)
        #expect(Array(outcomes.prefix(4)) == Array(repeating: .started, count: 4))
        #expect(Array(outcomes.dropFirst(4)) == Array(repeating: .queued, count: 6))
        #expect(admission.restoring == Set(keys.prefix(4)))
        #expect(admission.waiting.map(\.key) == Array(keys.dropFirst(4)))

        // One restore ends: the oldest waiting wake takes its slot, never more than four at once.
        let pump = admission.finished("tab0", pressure: .normal) { _ in true }
        #expect(pump.starts.map(\.key) == ["tab4"])
        #expect(admission.restoring.count == 4)
        #expect(admission.waiting.map(\.key) == Array(keys.dropFirst(5)))
    }

    @Test func aRepeatedRequestForAQueuedTabKeepsOnePlace() {
        let admission = Self.admission(cores: 2)
        #expect(admission.request("a", by: .automation, pressure: .normal) == .started)
        #expect(admission.request("b", by: .automation, pressure: .normal) == .queued)
        #expect(admission.request("b", by: .automation, pressure: .normal) == .queued)
        #expect(admission.waiting.map(\.key) == ["b"])
    }

    // MARK: Memory pressure and free memory

    @Test func atWarningTheQueuedAgentWakesAreDroppedWithATypedDeferral() {
        let admission = Self.admission(cores: 2)
        #expect(admission.request("a", by: .automation, pressure: .normal) == .started)
        #expect(admission.request("b", by: .automation, pressure: .normal) == .queued)
        #expect(admission.request("c", by: .prewarm, pressure: .normal) == .queued)
        let pump = admission.pressureDidChange(.warning)
        #expect(pump.starts.isEmpty)
        #expect(pump.deferred == ["b": .memoryPressure, "c": .memoryPressure])
        #expect(admission.waiting.isEmpty)
        #expect(admission.deferral(of: "b") == .memoryPressure)
        #expect(admission.deferral(of: "a") == nil, "the running restore was not asked to stop")
        // A new unrequested wake under pressure does not start or wait.
        #expect(admission.request("d", by: .automation, pressure: .warning) == .deferred(.memoryPressure))
        #expect(admission.request("e", by: .prewarm, pressure: .critical) == .deferred(.memoryPressure))
        #expect(admission.waiting.isEmpty)
    }

    @Test func noUnrequestedWakeStartsUnder150MBFree() {
        let low = Self.admission(cores: 8, free: 100 << 20)
        #expect(low.request("a", by: .automation, pressure: .normal) == .deferred(.lowFreeMemory))
        #expect(low.request("b", by: .prewarm, pressure: .normal) == .deferred(.lowFreeMemory))
        #expect(low.restoring.isEmpty)
        #expect(low.deferral(of: "a") == .lowFreeMemory)

        let enough = Self.admission(cores: 8, free: 200 << 20)
        #expect(enough.request("a", by: .automation, pressure: .normal) == .started)

        let unreadable = Self.admission(cores: 8, free: nil)
        #expect(unreadable.request("a", by: .automation, pressure: .normal) == .started, "an unreadable free count holds no wake back")
    }

    @Test func aSlotFreedWhileMemoryIsLowDropsTheWaitingWakes() {
        var free: UInt64 = Self.plenty
        let admission = WakeAdmission(isEnabled: true, cores: 2, freeBytes: { free })
        #expect(admission.request("a", by: .automation, pressure: .normal) == .started)
        #expect(admission.request("b", by: .automation, pressure: .normal) == .queued)
        free = 50 << 20
        let pump = admission.finished("a", pressure: .normal) { _ in true }
        #expect(pump.starts.isEmpty)
        #expect(pump.deferred == ["b": .lowFreeMemory])
        #expect(admission.waiting.isEmpty && admission.restoring.isEmpty)
    }

    @Test func aSlotFreedUnderPressureStartsNothing() {
        let admission = Self.admission(cores: 2)
        #expect(admission.request("a", by: .automation, pressure: .normal) == .started)
        #expect(admission.request("b", by: .automation, pressure: .normal) == .queued)
        let pump = admission.finished("a", pressure: .critical) { _ in true }
        #expect(pump.starts.isEmpty)
        #expect(pump.deferred == ["b": .memoryPressure])
    }

    @Test func aNewRequestClearsTheTabsLastDeferral() {
        let admission = Self.admission(cores: 2)
        _ = admission.request("a", by: .automation, pressure: .warning)
        #expect(admission.deferral(of: "a") == .memoryPressure)
        #expect(admission.request("a", by: .automation, pressure: .normal) == .started)
        #expect(admission.deferral(of: "a") == nil)
        _ = admission.request("b", by: .automation, pressure: .warning)
        admission.forget("b")
        #expect(admission.deferral(of: "b") == nil, "a closed tab keeps no deferral")
    }

    // MARK: The person

    @Test func aPersonsShowIsNeverQueued() {
        let admission = Self.admission(cores: 2, free: 0)
        #expect(admission.request("busy", by: .automation, pressure: .normal) == .deferred(.lowFreeMemory))
        let full = Self.admission(cores: 2)
        #expect(full.request("a", by: .automation, pressure: .normal) == .started)
        #expect(full.request("b", by: .automation, pressure: .normal) == .queued)
        // Every slot taken, memory pressure critical: a person's wake still starts at once and takes no slot.
        #expect(full.request("c", by: .person, pressure: .critical) == .started)
        #expect(full.restoring == ["a"])
        // A person's show of a tab whose agent wake waits starts it now and takes it out of the queue.
        #expect(full.request("b", by: .person, pressure: .normal) == .started)
        #expect(full.waiting.isEmpty)
        #expect(admission.request("d", by: .person, pressure: .normal) == .started, "no free memory floor for the person")
    }

    // MARK: Prewarms

    @Test func aCancelledPrewarmLeavesTheQueueButAnAgentsWakeStays() {
        let admission = Self.admission(cores: 2)
        #expect(admission.request("a", by: .automation, pressure: .normal) == .started)
        #expect(admission.request("neighbor", by: .prewarm, pressure: .normal) == .queued)
        #expect(admission.request("agent", by: .automation, pressure: .normal) == .queued)
        #expect(admission.request("both", by: .prewarm, pressure: .normal) == .queued)
        #expect(admission.request("both", by: .automation, pressure: .normal) == .queued)
        for key in ["neighbor", "agent", "both"] { admission.cancelPrewarm(key) }
        #expect(admission.waiting.map(\.key) == ["agent", "both"], "an agent waits on a wake a prewarm asked for first")
    }

    @Test func aPumpSkipsTabsThatWokeAnotherWayOrClosed() {
        let admission = Self.admission(cores: 2)
        #expect(admission.request("a", by: .automation, pressure: .normal) == .started)
        #expect(admission.request("shown", by: .prewarm, pressure: .normal) == .queued)
        #expect(admission.request("next", by: .automation, pressure: .normal) == .queued)
        let pump = admission.finished("a", pressure: .normal) { $0 != "shown" }
        #expect(pump.starts.map(\.key) == ["next"])
        #expect(admission.waiting.isEmpty)
    }

    @Test func offEveryWakeStartsAtOnce() {
        let admission = WakeAdmission(isEnabled: false, cores: 2, freeBytes: { 0 })
        for index in 0 ..< 10 {
            #expect(admission.request("tab\(index)", by: .automation, pressure: .critical) == .started)
        }
        #expect(admission.restoring.isEmpty && admission.waiting.isEmpty)
    }

    // MARK: Through the browser hibernation (real WebKit pages)

    @Test func theHibernationQueuesAnAgentsSecondWakeDefersItAtWarningAndNeverQueuesThePerson() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let agent = try await Self.hibernated(rig, "agent")
        let queued = try await Self.hibernated(rig, "queued")
        let shown = try await Self.hibernated(rig, "shown")
        rig.hibernation.pressureDidChange(.normal)
        rig.hibernation.admission = WakeAdmission(isEnabled: true, cores: 2, freeBytes: { Self.plenty })

        #expect(rig.hibernation.wake(agent, by: .automation) == .started)
        #expect(rig.hibernation.wake(queued, by: .automation) == .queued)
        #expect(rig.isHibernated(queued), "a queued wake restored its page")
        #expect(rig.hibernation.wake(shown), "the person's Wake Tab was refused")
        #expect(!rig.isHibernated(shown) || rig.services.cache.phase(of: shown) == .restoring, "the person's wake waited for a slot")

        rig.hibernation.pressureDidChange(.warning)
        #expect(rig.hibernation.admission.deferral(of: queued) == .memoryPressure)
        #expect(rig.hibernation.admission.waiting.isEmpty)
        #expect(rig.isHibernated(queued))
        let error = AppBrowserPage.wakeError(queued, cache: rig.services.cache)
        #expect(error.code == "deferred")
        #expect(error.data == JSONValue.object(["reason": .string("memoryPressure")]))
        #expect(AppBrowserPage.wakeError(agent, cache: rig.services.cache).code == "unavailable")
        // The agent's restore keeps its slot until its load ends, then frees it.
        try await rig.until("the agent's wake freed its slot") { rig.hibernation.admission.restoring.isEmpty }
    }

    private static func hibernated(_ rig: HiddenPageHibernationTests.Rig, _ name: String) async throws -> String {
        let key = try await rig.hide(rig.page(name, body: "<p>\(name)</p>"))
        try await rig.until("\(name) hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        try #require(rig.isHibernated(key))
        return key
    }
}
