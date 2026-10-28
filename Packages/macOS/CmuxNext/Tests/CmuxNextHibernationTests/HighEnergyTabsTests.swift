import CmuxNextHibernation
import CmuxNextWakeups
import Testing

/// A hidden tab whose renderers used more than 5 % of one core over at least 60 s says "Using high
/// energy" in its hover card, with Discard; one at 3 % does not, and a tab that shows never does (Chrome's
/// `CpuHealthTracker` acts on background tabs only). Readings happen only at wakes (the hibernation's replans and a
/// card's opening), never on a timer of the monitor's own. The renderer readings come from the `measure` seam, the
/// hidden tabs from `hidden`, the clock from `now`.
@MainActor @Suite struct HighEnergyTabsTests {
    /// A monitor over injected hidden tabs, readings and clock. Each reading is landed by hand with the given CPU time.
    @MainActor final class Rig {
        var hidden: [String: UInt64] = [:]
        var clock = ContinuousClock.now
        var discarded: [String] = []
        private(set) var requests: [(keys: [String], landed: @MainActor @Sendable (SaverCPUFreeze.Reading) -> Void)] = []
        private(set) lazy var monitor: HighEnergyTabMonitor = {
            let monitor = HighEnergyTabMonitor(measure: { [unowned self] keys, landed in self.requests.append((keys, landed)) },
                                               hidden: { [unowned self] in self.hidden },
                                               discard: { [unowned self] in self.discarded.append($0) })
            monitor.now = { [unowned self] in self.clock }
            return monitor
        }()

        func advance(_ seconds: Int) { clock += .seconds(seconds) }

        /// Lands the last request with each renderer's total CPU time and the tabs it serves.
        func land(_ renderers: [(pid: Int32, cpu: Duration, tabs: [String])]) throws {
            let request = try #require(requests.last, "no reading was asked for")
            request.landed(SaverCPUFreeze.Reading(renderers: renderers.map {
                SaverCPUFreeze.Reading.Renderer(id: ProcessUsage.Renderer(pid: $0.pid, clientID: $0.pid), cpu: $0.cpu, tabs: $0.tabs)
            }, at: clock))
        }

        /// A wake at the window's start and one a full window later, with `cpu` used in between by one renderer of `tabs`.
        func measureWindow(cpu: Duration, tabs: [String], start: Duration = .zero) throws {
            monitor.wake()
            try land([(pid: 10, cpu: start, tabs: tabs)])
            advance(60)
            monitor.wake()
            try land([(pid: 10, cpu: start + cpu, tabs: tabs)])
        }

        func flagged(_ key: String) -> Bool { monitor.usesHighEnergy(key) {} }
    }

    /// Hidden at 8 % of a core over 60 s: flagged.
    @Test func aHiddenTabAtEightPercentIsFlagged() throws {
        let rig = Rig()
        rig.hidden = ["busy": 1]
        try rig.measureWindow(cpu: .milliseconds(4800), tabs: ["busy"])
        #expect(abs((rig.monitor.rule.measured["busy"]?.share ?? 0) - 0.08) < 1e-9)
        #expect(rig.flagged("busy"))
    }

    /// Hidden at 3 %: measured, not flagged.
    @Test func aHiddenTabAtThreePercentIsNotFlagged() throws {
        let rig = Rig()
        rig.hidden = ["quiet": 1]
        try rig.measureWindow(cpu: .milliseconds(1800), tabs: ["quiet"])
        #expect(abs((rig.monitor.rule.measured["quiet"]?.share ?? 1) - 0.03) < 1e-9)
        #expect(!rig.flagged("quiet"))
    }

    /// A tab that shows is never flagged: not while it shows, not when it hides again until a new whole window, and a
    /// visible tab sharing a busy hidden tab's renderer is never flagged.
    @Test func aVisibleTabIsNeverFlagged() throws {
        let rig = Rig()
        rig.hidden = ["busy": 1]
        // "shown" shares the renderer: 16 % split two ways, 8 % each.
        try rig.measureWindow(cpu: .milliseconds(9600), tabs: ["busy", "shown"])
        #expect(rig.flagged("busy"))
        #expect(!rig.flagged("shown"), "a tab that shows was flagged")
        rig.hidden = [:]
        #expect(!rig.flagged("busy"), "a tab that shows now kept its flag")
        // Hidden again: a new hide (generation) starts a new window; the old share does not come back.
        rig.hidden = ["busy": 3]
        rig.advance(10)
        #expect(!rig.flagged("busy"), "a new hide reused the share of the last one")
    }

    /// A share needs a whole window of one hide: a reading after 30 s gives none, and a tab hidden again inside the
    /// window starts over.
    @Test func aShareNeedsAWholeWindowOfOneHide() throws {
        let rig = Rig()
        rig.hidden = ["busy": 1]
        rig.monitor.wake()
        try rig.land([(pid: 10, cpu: .zero, tabs: ["busy"])])
        // Another tab hides 30 s later: its first reading is a reading of "busy" too, 30 s into its window.
        rig.advance(30)
        rig.hidden["other"] = 2
        rig.monitor.wake()
        #expect(rig.requests.count == 2)
        try rig.land([(pid: 10, cpu: .seconds(3), tabs: ["busy"]), (pid: 11, cpu: .zero, tabs: ["other"])])
        #expect(rig.monitor.rule.measured["busy"] == nil, "a 30 s window gave a share")
        // Shown and hidden again 30 s later: the window of the first hide is gone, and 60 s after the first reading
        // there is no share of either hide.
        rig.hidden["busy"] = 3
        rig.advance(30)
        rig.monitor.wake()
        #expect(rig.requests.count == 3)
        try rig.land([(pid: 10, cpu: .seconds(6), tabs: ["busy"]), (pid: 11, cpu: .zero, tabs: ["other"])])
        #expect(rig.monitor.rule.measured["busy"] == nil, "a window spanning two hides gave a share")
        #expect(rig.monitor.rule.measured["other"] == nil, "a 30 s window gave a share")
    }

    /// Readings happen only at wakes, at most one per 10 s, and only when a hidden tab needs one: no timer of its own.
    @Test func readingsHappenOnlyAtWakes() throws {
        let rig = Rig()
        rig.monitor.wake()
        #expect(rig.requests.isEmpty, "a reading with no hidden tab")
        rig.hidden = ["busy": 1]
        rig.monitor.wake()
        rig.monitor.wake()
        #expect(rig.requests.count == 1, "a reading already out was asked for again")
        try rig.land([(pid: 10, cpu: .zero, tabs: ["busy"])])
        rig.advance(5)
        rig.monitor.wake()
        #expect(rig.requests.count == 1, "two readings within the spacing")
        rig.advance(300)
        #expect(rig.requests.count == 1, "time alone took a reading")
        rig.monitor.wake()
        #expect(rig.requests.count == 2)
        #expect(rig.requests.last?.keys == ["busy"])
    }

    /// A card that asks while its tab's reading is out shows the answer when the reading lands.
    @Test func aCardRefreshesWhenItsReadingLands() throws {
        let rig = Rig()
        rig.hidden = ["busy": 1]
        rig.monitor.wake()
        try rig.land([(pid: 10, cpu: .zero, tabs: ["busy"])])
        rig.advance(60)
        var refreshed = 0
        // The card's opening is the wake that asks for the reading.
        #expect(!rig.monitor.usesHighEnergy("busy") { refreshed += 1 })
        #expect(rig.requests.count == 2)
        try rig.land([(pid: 10, cpu: .seconds(6), tabs: ["busy"])])
        #expect(refreshed == 1)
        #expect(rig.flagged("busy"))
    }

    /// A share an hour old says nothing about the tab now: a tab flagged at 60 s that idled since is not flagged when
    /// its card asks an hour later, before the fresh reading lands, nor after it (it idled).
    @Test func aShareFromLongAgoIsNotFlaggedBeforeTheFreshReadingLands() throws {
        let rig = Rig()
        rig.hidden = ["busy": 1]
        try rig.measureWindow(cpu: .milliseconds(4800), tabs: ["busy"])
        #expect(rig.flagged("busy"))
        rig.advance(3540)
        var refreshed = 0
        #expect(!rig.monitor.usesHighEnergy("busy") { refreshed += 1 }, "the card showed an hour-old high-energy flag")
        #expect(rig.requests.count == 3, "the card's question asked for no fresh reading")
        // Idle since: the renderer's CPU time did not move.
        try rig.land([(pid: 10, cpu: .milliseconds(4800), tabs: ["busy"])])
        #expect(refreshed == 1)
        #expect(!rig.flagged("busy"), "an idle tab kept its flag after the fresh reading")
    }

    /// A renderer whose CPU time went back (a new process on its id) adds nothing.
    @Test func aRendererWhoseTimeWentBackAddsNothing() throws {
        let rig = Rig()
        rig.hidden = ["busy": 1]
        try rig.measureWindow(cpu: .seconds(-5), tabs: ["busy"], start: .seconds(10))
        #expect(rig.monitor.rule.measured["busy"]?.share == 0)
        #expect(!rig.flagged("busy"))
    }

    /// Discard goes to the App's Hibernate Tab path for that tab.
    @Test func discardRunsTheTabsDiscard() {
        let rig = Rig()
        rig.monitor.discard("busy")
        #expect(rig.discarded == ["busy"])
    }
}
