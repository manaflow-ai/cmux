import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// Wakes nobody asked for (an agent's or a script's call on a hibernated tab, a neighbor or
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
        let pump = admission.pressureDidChange(.warning) { _ in true }
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
        admission.leftHibernation("b")
        #expect(admission.deferral(of: "b") == nil, "a closed tab keeps no deferral")
    }

    @Test func aTabThatLeftHibernationKeepsNoDeferralOrPlace() {
        let admission = Self.admission(cores: 2)
        _ = admission.request("a", by: .automation, pressure: .warning)
        #expect(admission.deferral(of: "a") == .memoryPressure)
        admission.leftHibernation("a")
        #expect(admission.deferral(of: "a") == nil, "a deferral outlived the tab's hibernation")

        #expect(admission.request("b", by: .automation, pressure: .normal) == .started)
        #expect(admission.request("c", by: .automation, pressure: .normal) == .queued)
        admission.leftHibernation("c")
        #expect(admission.waiting.isEmpty, "a tab a person woke kept its place in the queue")
    }

    @Test func atWarningAWaitingTabAPersonAlreadyWokeIsNotDeferred() {
        let admission = Self.admission(cores: 2)
        #expect(admission.request("a", by: .automation, pressure: .normal) == .started)
        #expect(admission.request("shown", by: .automation, pressure: .normal) == .queued)
        #expect(admission.request("asleep", by: .automation, pressure: .normal) == .queued)
        let pump = admission.pressureDidChange(.warning) { $0 != "shown" }
        #expect(pump.deferred == ["asleep": .memoryPressure])
        #expect(admission.deferral(of: "shown") == nil, "a tab the person is restoring got a deferral")
        #expect(admission.waiting.isEmpty)
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
        #expect(rig.hibernation.wake(shown, origin: .user) != .notHibernated, "the person's Wake Tab was refused")
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

    /// A person's show restores a tab with no admission request (`ContentLifecycle` `.show`): an agent's call
    /// on a tab whose wake was deferred, made while that restore runs or after it, is never answered `deferred`.
    @Test func anAgentCallOnATabThePersonShowsAfterADeferralIsNotDeferred() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let restoring = try await Self.hibernated(rig, "restoring")
        let shown = try await Self.hibernated(rig, "shown")
        let cache = rig.services.cache
        rig.hibernation.pressureDidChange(.normal)
        rig.hibernation.admission = WakeAdmission(isEnabled: true, cores: 2, freeBytes: { Self.plenty })
        rig.hibernation.pressureDidChange(.warning)
        #expect(rig.hibernation.wake(restoring, by: .automation) == .deferred(.memoryPressure))
        #expect(rig.hibernation.wake(shown, by: .automation) == .deferred(.memoryPressure))

        // A restore in flight, as a Chromium page's is: the placeholder stays installed until the page lands.
        let effects = cache.lifecycle.send(.wake(restoring))
        try #require(cache.phase(of: restoring) == .restoring && rig.isHibernated(restoring))
        #expect(rig.hibernation.deferral(of: restoring) == nil, "a restoring tab reads as deferred")
        #expect(AppBrowserPage.wakeError(restoring, cache: cache).code == "unavailable")
        let placeholder = try #require(cache.browsers[restoring]?.tab)
        let call = Task { @MainActor in
            await AppBrowserPage.awakePage(restoring, page: placeholder, cache: cache, within: .seconds(10))
        }
        for _ in 0 ..< 16 { await Task.yield() }
        #expect(rig.hibernation.admission.deferral(of: restoring) == nil, "the agent's call left the stale deferral")
        cache.applyLifecycle(effects)
        let live = await call.value
        #expect(live.map { !($0 is HibernatedBrowserTab) } == true, "the agent's call during the restore got no live page")

        // The person's show itself.
        cache.present(shown, by: rig.pane, presence: .visible)
        #expect(!rig.isHibernated(shown), "the person's show did not restore the page at warning pressure")
        #expect(rig.hibernation.admission.deferral(of: shown) == nil, "the shown tab kept its deferral")
        #expect(AppBrowserPage.wakeError(shown, cache: cache).code == "unavailable")
    }

    /// Wake Tab from the CLI, MCP or a script is an agent's wake: it takes a slot and is deferred at warning.
    /// Only the person's run (origin `.user`) skips the admission.
    @Test func aWakeTabRunFromTheCLIIsAdmittedAsAnAgentsWake() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let cli = try await Self.hibernated(rig, "cli")
        let mcp = try await Self.hibernated(rig, "mcp")
        let person = try await Self.hibernated(rig, "person")
        rig.hibernation.pressureDidChange(.normal)
        rig.hibernation.admission = WakeAdmission(isEnabled: true, cores: 2, freeBytes: { Self.plenty })
        // The one slot is taken by a restore that does not end in this test.
        #expect(rig.hibernation.admission.request("busy", by: .automation, pressure: .normal) == .started)

        #expect(rig.hibernation.wake(cli, origin: .cli) == .queued, "a CLI Wake Tab skipped the full admission")
        #expect(rig.isHibernated(cli))
        #expect(rig.hibernation.wake(person, origin: .user) == .started, "the person's Wake Tab waited for a slot")
        rig.hibernation.pressureDidChange(.warning)
        #expect(rig.hibernation.deferral(of: cli) == .memoryPressure)
        #expect(rig.hibernation.wake(mcp, origin: .mcp) == .deferred(.memoryPressure), "an MCP Wake Tab started at warning pressure")
        #expect(rig.isHibernated(cli) && rig.isHibernated(mcp))
    }

    /// A DevTools attach waits for its page's install; a queued wake dropped at warning installs none, so the
    /// wait ends at the drop, and a capture of that page answers `screenshot.deferred` with the deferral.
    @Test func aDevToolsWaitOnAQueuedWakeEndsWhenTheWakeIsDropped() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let queued = try await Self.hibernated(rig, "queued")
        let cache = rig.services.cache, hibernation = rig.hibernation
        hibernation.pressureDidChange(.normal)
        hibernation.admission = WakeAdmission(isEnabled: true, cores: 2, freeBytes: { Self.plenty })
        #expect(hibernation.admission.request("busy", by: .automation, pressure: .normal) == .started)
        #expect(hibernation.wake(queued, by: .automation) == .queued)
        #expect(ScreenshotHandlers.wakeFailure(queued, cache: cache).code == ScreenshotHandlers.unavailableCode)

        let wait = Task { @MainActor in
            await AppDevToolsRelay.nextPageInstall(of: cache.pageInstalls, on: rig.services.mainWork) {
                hibernation.deferral(of: queued) != nil
            }
        }
        for _ in 0 ..< 16 { await Task.yield() }
        hibernation.pressureDidChange(.warning)
        await wait.value
        #expect(rig.isHibernated(queued))
        #expect(hibernation.deferral(of: queued) == .memoryPressure)

        let failure = ScreenshotHandlers.wakeFailure(queued, cache: cache)
        #expect(failure.code == ScreenshotHandlers.deferredCode)
        #expect(failure.details == ["deferral": "memoryPressure"])
    }

    private static func hibernated(_ rig: HiddenPageHibernationTests.Rig, _ name: String) async throws -> String {
        let key = try await rig.hide(rig.page(name, body: "<p>\(name)</p>"))
        try await rig.until("\(name) hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        try #require(rig.isHibernated(key))
        return key
    }
}
