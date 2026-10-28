import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeupsTestSupport
import Testing

/// `debug.damage`: the owner table render-idle-damage.py turns into the
/// MQ-damage-owners queue. The hooks are process-wide (RenderStatsTests owns them), so the window's
/// arm, re-start, stop and expiry logic runs against a fake ``RenderCounting`` and a fake display-pass probe.
@MainActor
struct RenderDamageWindowTests {
    private func totals(_ values: [RenderStats.Counter: Int]) -> RenderStats.Totals {
        var totals = RenderStats.Totals()
        for (counter, value) in values { totals[counter] = value }
        return totals
    }

    /// Only owners with damage (draws plus contents sets) in the window are listed, most first, merged by
    /// name; counts from before `start` are subtracted; Ghostty frames are its layer owners' contents sets.
    @Test func ownersWithDamageAreListedMostFirstAndGhosttyFramesAreItsContentsSets() {
        let names: [UInt: String] = [1: "SidebarRowView", 2: "TerminalSurfaceView", 3: "IOSurfaceLayer", 4: "PaneDivider",
                                     5: "SidebarRowView", 6: "SpinnerView"]
        let start: [UInt: RenderStats.Totals] = [1: totals([.damageRects: 4]), 2: totals([.contentsSets: 10]),
                                                 4: totals([.frameSets: 2]), 6: totals([.damageRects: 7, .damageArea: 70])]
        let end: [UInt: RenderStats.Totals] = [
            1: totals([.damageRects: 10, .damageArea: 600]),
            2: totals([.contentsSets: 30]),
            3: totals([.contentsSets: 5]),
            4: totals([.frameSets: 9, .layouts: 3]),
            5: totals([.damageRects: 1, .damageArea: 50]),
            6: totals([.damageRects: 7, .damageArea: 70]),
        ]
        let counts = RenderDamageWindow.counts(start: start, end: end, totals: totals([.damageRects: 7, .contentsSets: 25]),
                                               names: names, seconds: 10, ghosttyOwners: ["TerminalSurfaceView", "IOSurfaceLayer"],
                                               displayPasses: 3, hiddenLoops: ["SpinnerView": 2])
        #expect(counts.owners.map(\.name) == ["TerminalSurfaceView", "SidebarRowView", "IOSurfaceLayer"])
        #expect(counts.owners.map { RenderDamageWindow.damage($0.totals) } == [20, 7, 5])
        #expect(counts.owners[1].totals[.damageArea] == 650)
        #expect(counts.ghosttyFrames == 25)

        let reply = RenderDamageWindow.Report(counts: counts).foundationObject
        #expect(reply["available"] as? Bool == true)
        #expect(reply["running"] as? Bool == false)
        #expect(reply["damage"] as? Int == 32)
        #expect(reply["damage_per_s"] as? Double == 3.2)
        let owners = reply["owners"] as? [[String: Any]] ?? []
        #expect(owners.map { $0["owner"] as? String } == ["TerminalSurfaceView", "SidebarRowView", "IOSurfaceLayer"])
        #expect(owners.first?["damage_per_s"] as? Double == 2)
        #expect(owners.dropFirst().first?["damage_area"] as? Int == 650)
        #expect(owners.dropFirst().first?["frame_sets"] == nil)
        let ghostty = reply["ghostty"] as? [String: Any] ?? [:]
        #expect(ghostty["frames"] as? Int == 25)
        #expect(ghostty["frames_per_s"] as? Double == 2.5)
        #expect(ghostty["display_calls"] as? Int == 3)
        #expect(reply["hidden_looping_animations"] as? Int == 2)
        #expect((reply["totals"] as? [String: Any])?["contents_sets"] as? Int == 25)
        #expect(JSONSerialization.isValidJSONObject(reply))
    }

    /// No damage, no owners: the idle target, and no rate from a zero-length window.
    @Test func anIdleWindowListsNoOwners() {
        let counts = RenderDamageWindow.counts(start: [:], end: [1: totals([.frameSets: 1])], totals: totals([.frameSets: 1]),
                                               names: [1: "PaneView"], seconds: 0, ghosttyOwners: [], displayPasses: nil,
                                               hiddenLoops: [:])
        #expect(counts.owners.isEmpty)
        let reply = RenderDamageWindow.Report(running: true, counts: counts).foundationObject
        #expect((reply["owners"] as? [Any])?.isEmpty == true)
        #expect(reply["damage_per_s"] as? Double == 0)
        #expect((reply["ghostty"] as? [String: Any])?["display_calls"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(reply))
    }

    /// Before any window, `read` and `stop` say nothing runs (a DEBUG test build has the hooks), and the
    /// display-pass probe is never touched.
    @Test func withNoWindowReadAndStopSayNotRunning() {
        let passes = FakePasses()
        let window = RenderDamageWindow(stats: RenderStats(), displayPasses: passes, ghosttyOwners: ["TerminalSurfaceView"],
                                        windows: { [] })
        #if DEBUG || CMUX_BENCH_HOOKS
        #expect(window.read() == RenderDamageWindow.Report())
        #expect(window.stop() == RenderDamageWindow.Report())
        #else
        #expect(window.read() == .unavailable)
        #endif
        #expect(!window.isRunning)
        #expect(passes.arms == 0 && passes.disarms == 0)
    }

    /// A build without the hooks answers `available: false` with the reason.
    @Test func theUnavailableReplySaysWhy() {
        let reply = RenderDamageWindow.Report.unavailable.foundationObject
        #expect(reply["available"] as? Bool == false)
        #expect((reply["error"] as? String)?.contains("CMUX_BENCH_HOOKS") == true)
        #expect(reply["owners"] == nil)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// One arm of the counts is held across a re-start, the window's counts are differences from its
    /// (last) start, and stop ends both arms.
    @Test func aWindowHoldsOneArmAcrossARestartAndCountsFromItsStart() async {
        let stats = FakeStats()
        let passes = FakePasses()
        let window = RenderDamageWindow(stats: stats, displayPasses: passes, ghosttyOwners: ["IOSurfaceLayer"], windows: { [] },
                                        clock: ManualClock())
        stats.add(owner: 1, name: "SidebarRowView", totals([.damageRects: 50]))
        passes.passCount = 40
        #expect(await window.start() == RenderDamageWindow.Report(running: true))
        #expect(stats.arms == 1 && passes.arms == 1)
        stats.add(owner: 1, name: "SidebarRowView", totals([.damageRects: 3]))
        stats.add(owner: 2, name: "IOSurfaceLayer", totals([.contentsSets: 4]))
        passes.passCount = 45
        #expect(window.read().counts?.owners.map(\.name) == ["IOSurfaceLayer", "SidebarRowView"])
        #expect(window.read().counts?.displayPasses == 5)

        #expect(await window.start() == RenderDamageWindow.Report(running: true))
        #expect(stats.arms == 1 && passes.arms == 1)
        stats.add(owner: 1, name: "SidebarRowView", totals([.damageRects: 2]))
        passes.passCount = 47
        let report = window.stop()
        #expect(report.running == false)
        #expect(report.counts?.owners.map(\.name) == ["SidebarRowView"])
        #expect(report.counts?.owners.first?.totals[.damageRects] == 2)
        #expect(report.counts?.ghosttyFrames == 0)
        #expect(report.counts?.displayPasses == 2)
        #expect(stats.arms == 0 && passes.arms == 0)
        #expect(window.read() == report)
        #expect(!window.isRunning)
    }

    /// A stop while the hooks are still going in makes that start answer an error, and no arm stays held.
    @Test func aStopBeforeTheHooksCountEndsTheStartWithAnErrorAndNoArm() async {
        let stats = FakeStats()
        stats.holdsReady = true
        let passes = FakePasses()
        let window = RenderDamageWindow(stats: stats, displayPasses: passes, ghosttyOwners: [], windows: { [] }, clock: ManualClock())
        let started = Task { await window.start() }
        await stats.waitForReadyCall()
        #expect(window.stop() == RenderDamageWindow.Report())
        stats.releaseReady(counting: false)
        let reply = await started.value
        #expect(reply.error?.contains("not counting") == true)
        #expect(stats.arms == 0 && passes.arms == 0)
        #expect(!window.isRunning)
    }

    /// The window holds its own nested arm of the display-pass probe, so a session that armed it first
    /// keeps its arm after the window stops; a probe that cannot count gives `display_calls` null.
    @Test func theDisplayPassArmIsTheWindowsOwn() async {
        let stats = FakeStats()
        let passes = FakePasses()
        passes.arms = 1 // a debug.terminal_display session
        let window = RenderDamageWindow(stats: stats, displayPasses: passes, ghosttyOwners: [], windows: { [] }, clock: ManualClock())
        _ = await window.start()
        #expect(passes.arms == 2)
        _ = window.stop()
        #expect(passes.arms == 1)

        let dead = FakePasses()
        dead.canArm = false
        let blind = RenderDamageWindow(stats: FakeStats(), displayPasses: dead, ghosttyOwners: [], windows: { [] }, clock: ManualClock())
        _ = await blind.start()
        dead.passCount = 9
        let report = blind.stop()
        #expect(report.counts != nil && report.counts?.displayPasses == nil)
        #expect((report.foundationObject["ghostty"] as? [String: Any])?["display_calls"] is NSNull)
        #expect(dead.arms == 0)
    }

    /// A window nobody stops ends by itself after ``RenderDamageWindow/maximumRun`` and lets its arms go.
    @Test func aWindowEndsByItselfAfterItsMaximumRun() async throws {
        let stats = FakeStats()
        let passes = FakePasses()
        let clock = ManualClock()
        let window = RenderDamageWindow(stats: stats, displayPasses: passes, ghosttyOwners: [], windows: { [] }, clock: clock)
        _ = await window.start()
        try await clock.waitForSleeper()
        clock.advance(by: RenderDamageWindow.maximumRun)
        for _ in 0..<50 where window.isRunning { await Task.yield() }
        #expect(!window.isRunning)
        #expect(stats.arms == 0 && passes.arms == 0)
        #expect(window.read().counts?.seconds == 900)
    }
    #endif

    @MainActor final class FakePasses: DisplayPassSource {
        var arms = 0
        var disarms = 0
        var canArm = true
        var passCount = 0
        func armPasses() -> Bool {
            guard canArm else { return false }
            arms += 1
            return true
        }

        func disarmPasses() {
            disarms += 1
            arms -= 1
        }
    }

    /// Counts the test sets by hand; ``ready()`` can be held until the test releases it.
    @MainActor final class FakeStats: RenderCounting {
        private(set) var arms = 0
        var holdsReady = false
        private var counting = true
        private var byOwner: [UInt: RenderStats.Totals] = [:]
        private var names: [UInt: String] = [:]
        private var readyWaiter: CheckedContinuation<Void, Never>?
        private var readyCalled: CheckedContinuation<Void, Never>?
        private var sawReady = false

        func add(owner: UInt, name: String, _ delta: RenderStats.Totals) {
            names[owner] = name
            var sum = byOwner[owner] ?? RenderStats.Totals()
            for counter in RenderStats.Counter.allCases { sum[counter] += delta[counter] }
            byOwner[owner] = sum
        }

        func arm() -> Bool {
            arms += 1
            return true
        }

        func ready() async -> Bool {
            sawReady = true
            readyCalled?.resume()
            readyCalled = nil
            if holdsReady { await withCheckedContinuation { readyWaiter = $0 } }
            return counting && arms > 0
        }

        func waitForReadyCall() async {
            if sawReady { return }
            await withCheckedContinuation { readyCalled = $0 }
        }

        func releaseReady(counting: Bool) {
            self.counting = counting
            readyWaiter?.resume()
            readyWaiter = nil
        }

        func disarm() { arms -= 1 }

        var totals: RenderStats.Totals {
            var sum = RenderStats.Totals()
            for owner in byOwner.values {
                for counter in RenderStats.Counter.allCases { sum[counter] += owner[counter] }
            }
            return sum
        }

        func ownerTotals() -> [UInt: RenderStats.Totals] { byOwner }

        func owners() -> [RenderStats.Owner] {
            byOwner.map { RenderStats.Owner(key: $0.key, name: names[$0.key] ?? "unnamed", totals: $0.value) }
        }
    }
}
