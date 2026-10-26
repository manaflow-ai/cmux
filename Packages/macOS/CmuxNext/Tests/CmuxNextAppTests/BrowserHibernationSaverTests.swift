import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextHibernation
@testable import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Energy Saver freezes CPU-heavy hidden tabs (p14-energy-039), Chrome's `FreezingPolicy` under battery saver: a
/// hidden page at `kFreezingHighCPUProportion` (25 % of one core) or more over its reading window freezes at the
/// next replan; a quiet page keeps `browser.freezeHiddenTabs`; the freeze probe's reasons (playing media) still keep
/// a busy page; out of the saver nothing is read and nothing changes. The renderer CPU readings come from the
/// `measureCPU` seam, the clock from `now`, and the freezes go to a recorder (`freezer`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct BrowserHibernationSaverTests {
    static let grace: Double = 30

    /// Saver, hidden at 30 %: frozen after one reading window, long before the 30 s grace.
    @Test func aBusyHiddenTabFreezesEarlyInTheSaver() async throws {
        let rig = try await Rig(saver: true, pages: ["busy"])
        defer { rig.close() }
        try await rig.step(10, cpu: ["busy": .seconds(3)])
        #expect(abs((rig.hibernation.saverCPU.proportions["busy"] ?? 0) - 0.3) < 1e-9)
        try await rig.until("the busy page freezes") { rig.hibernation.frozen.contains("busy") }
        #expect(rig.recorders["busy"]?.calls == [true])
    }

    /// Saver, hidden at 1 %: no early freeze; it freezes at the grace, as out of the saver.
    @Test func aQuietHiddenTabKeepsTheGrace() async throws {
        let rig = try await Rig(saver: true, pages: ["quiet"])
        defer { rig.close() }
        try await rig.step(10, cpu: ["quiet": .milliseconds(100)])
        try await rig.step(10, cpu: ["quiet": .milliseconds(100)])
        #expect(abs((rig.hibernation.saverCPU.proportions["quiet"] ?? 1) - 0.01) < 1e-9)
        #expect(!rig.hibernation.frozen.contains("quiet"))
        #expect(rig.recorders["quiet"]?.calls.isEmpty == true, "a quiet page froze before the grace")
        rig.advance(to: Self.grace)
        try await rig.until("the quiet page freezes at the grace") { rig.hibernation.frozen.contains("quiet") }
    }

    /// Saver, playing at 30 %: the freeze probe keeps it, as Chrome's `CannotFreezeReason`s keep a busy page; a silent
    /// page as busy beside it freezes.
    @Test func aPlayingBusyTabDoesNotFreeze() async throws {
        let rig = try await Rig(saver: true, pages: ["playing", "silent"], playing: ["playing"])
        defer { rig.close() }
        try await rig.step(10, cpu: ["playing": .seconds(3), "silent": .seconds(3)])
        #expect(abs((rig.hibernation.saverCPU.proportions["playing"] ?? 0) - 0.3) < 1e-9)
        try await rig.until("the silent page freezes") { rig.hibernation.frozen.contains("silent") }
        try await rig.until("the playing page was asked") { rig.evaluations("playing") >= 2 }
        await rig.settle()
        #expect(!rig.hibernation.frozen.contains("playing"))
        #expect(rig.recorders["playing"]?.calls.isEmpty == true, "a page that plays froze")
    }

    /// Out of the saver at 30 %: nothing is read and the page freezes at the grace, as before the rule.
    @Test func outOfTheSaverNothingChanges() async throws {
        let rig = try await Rig(saver: false, pages: ["busy"])
        defer { rig.close() }
        rig.advance(to: 10, cpu: ["busy": .seconds(3)])
        await rig.settle()
        #expect(rig.reads == 0, "out of the saver the renderers were read")
        #expect(rig.hibernation.saverCPU.lastReadingAt == nil)
        #expect(!rig.hibernation.frozen.contains("busy"), "out of the saver a busy page froze before the grace")
        rig.advance(to: Self.grace)
        try await rig.until("the busy page freezes at the grace") { rig.hibernation.frozen.contains("busy") }
    }

    /// The saver ends before the second reading: its readings go, and the busy page waits for the grace.
    @Test func theSaverEndingDropsItsReadings() async throws {
        let rig = try await Rig(saver: true, pages: ["busy"])
        defer { rig.close() }
        rig.energy.update(.normal)
        rig.advance(to: 10, cpu: ["busy": .seconds(3)])
        await rig.settle()
        #expect(rig.hibernation.saverCPU.lastReadingAt == nil, "the saver's readings outlived it")
        #expect(rig.reads == 1)
        #expect(!rig.hibernation.frozen.contains("busy"))
    }

    // MARK: The rule alone

    /// A page that showed after its baseline starts a new window: time it showed is not counted as hidden.
    @Test func aPageShownSinceItsBaselineStartsAgain() throws {
        let start = ContinuousClock.now
        var rule = SaverCPUFreeze()
        let first = try #require(rule.pastGrace([.init(key: "a", hiddenFor: 0)], saver: true, now: start).read)
        #expect(rule.land(.init(cpu: ["a": .zero], at: start), generation: first.generation))
        let second = try #require(rule.pastGrace([.init(key: "a", hiddenFor: 10)], saver: true, now: start + .seconds(10)).read)
        #expect(rule.land(.init(cpu: ["a": .seconds(5)], at: start + .seconds(10)), generation: second.generation))
        #expect(abs((rule.proportions["a"] ?? 0) - 0.5) < 1e-9)
        // Hidden again 1 s ago, after both readings: its share is dropped, so it does not count as past the grace.
        let planned = rule.pastGrace([.init(key: "a", hiddenFor: 1)], saver: true, now: start + .seconds(12))
        #expect(planned.candidates.first?.hiddenFor == 1)
        #expect(planned.read == nil, "a reading was asked for inside the window")
        #expect(rule.proportions["a"] == nil)
    }

    /// A reading asked for before the saver ended lands on nothing, even once the saver is back and asked again.
    @Test func aReadingFromAnEndedSaverIsDropped() throws {
        let start = ContinuousClock.now
        var rule = SaverCPUFreeze()
        let stale = try #require(rule.pastGrace([.init(key: "a", hiddenFor: 0)], saver: true, now: start).read)
        _ = rule.pastGrace([.init(key: "a", hiddenFor: 1)], saver: false, now: start + .seconds(1))
        let fresh = try #require(rule.pastGrace([.init(key: "a", hiddenFor: 2)], saver: true, now: start + .seconds(2)).read)
        #expect(!rule.land(.init(cpu: ["a": .zero], at: start), generation: stale.generation))
        #expect(rule.lastReadingAt == nil)
        #expect(rule.land(.init(cpu: ["a": .zero], at: start + .seconds(2)), generation: fresh.generation))
    }

    /// A renderer two tabs share is split between them: a hidden page beside a busy shown page of its site is not busy.
    @Test func aSharedRendererIsSplitBetweenItsTabs() {
        func usage(pid: pid_t, cpu: UInt64) -> ProcessUsage {
            ProcessUsage(pid: pid, parent: 1, path: "renderer", cpuNanos: cpu, wakeups: 0, interruptWakeups: 0,
                         packageIdleWakeups: 0, energyNanojoules: 0, physFootprint: 0, uptimeNanos: 0)
        }
        let tabs = [
            ProcessUsage.TabRenderers(tab: "shown", title: "", pid: 10, rendererClients: [1]),
            ProcessUsage.TabRenderers(tab: "hidden", title: "", pid: 10, rendererClients: [1, 2]),
        ]
        let renderers = [
            (renderer: ProcessUsage.Renderer(pid: 10, clientID: 1), usage: usage(pid: 10, cpu: 8_000_000_000)),
            (renderer: ProcessUsage.Renderer(pid: 11, clientID: 2), usage: usage(pid: 11, cpu: 1_000_000_000)),
        ]
        let cpu = SaverCPUFreeze.cpuTime(ProcessUsage.perTab(tabs, renderers: renderers))
        #expect(cpu["shown"] == .seconds(4))
        #expect(cpu["hidden"] == .seconds(5))
    }

    // MARK: Rig

    /// Records `setFrozen` calls for one page.
    @MainActor final class Recorder: BrowserFreezing {
        var calls: [Bool] = []
        func setFrozen(_ frozen: Bool) -> Bool { calls.append(frozen); return true }
    }

    /// App services and a browser hibernation (freeze grace 30 s, hibernation off) on a test clock, with mock pages
    /// hidden at its start and a renderer CPU table the test fills.
    @MainActor final class Rig {
        /// The page probe's answers: nothing plays, or media plays.
        static let silentAnswer = #"{"media":false,"form":false,"sound":false}"#
        static let playingAnswer = #"{"media":true,"form":false,"sound":true}"#

        let services: AppServices
        let hibernation: BrowserHibernation
        let energy: EnergyPolicySource
        let engine = MockBrowserEngine()
        let pane = Pane()
        let start: ContinuousClock.Instant
        var instant: ContinuousClock.Instant
        var cpu: [String: Duration] = [:]
        var reads = 0
        var tabs: [String: MockBrowserTab] = [:]
        var recorders: [String: Recorder] = [:]

        /// Hides `pages` at the start, then turns the saver on when `saver` asks and waits for its first reading (the
        /// pages' baseline): a reading started by the first hide would miss the pages hidden after it.
        init(saver: Bool, pages: [String], playing: Set<String> = []) async throws {
            _ = NSApplication.shared
            let now = ContinuousClock.now
            start = now
            instant = now
            services = AppServices(environment: AppEnvironment.current([:]))
            energy = EnergyPolicySource(.normal)
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(),
                                             deadlines: services.mainDeadlines, energy: energy)
            services.cache.hibernation = hibernation
            hibernation.now = { [weak self] in self?.instant ?? .now }
            hibernation.freezer = { [weak self] tab in self?.recorders[tab.id.rawValue] }
            // The renderers' CPU table at the clock's instant, landing on a later main-actor turn as the app's reply does.
            hibernation.measureCPU = { [weak self] keys, landed in
                guard let self else { return }
                self.reads += 1
                let reading = SaverCPUFreeze.Reading(cpu: self.cpu.filter { keys.contains($0.key) }, at: self.instant)
                Task { landed(reading) }
            }
            hibernation.apply(BrowserHibernationSetting(mode: .off, freezeSeconds: BrowserHibernationSaverTests.grace))
            hibernation.start()
            for key in pages { hide(key, playing: playing.contains(key)) }
            guard saver else { return }
            energy.update(EnergyPolicy(saverReason: .setting))
            try await step(0, cpu: [:])
        }

        private func hide(_ key: String, playing: Bool) {
            let tab = engine.makeMockTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key)))
            tab.evaluationResult = .string(playing ? Self.playingAnswer : Self.silentAnswer)
            tabs[key] = tab
            recorders[key] = Recorder()
            cpu[key] = .zero
            _ = services.cache.install(tab, for: key)
            services.cache.present(key, by: pane, presence: .visible)
            services.cache.withdraw(key, by: pane)
        }

        /// Moves the clock to `seconds` after the start, adds `cpu` to the pages' renderer time, and replans (a
        /// natural wake: a tab switch, a deadline).
        func advance(to seconds: Double, cpu added: [String: Duration] = [:]) {
            instant = start + .seconds(seconds)
            for (key, more) in added { cpu[key, default: .zero] += more }
            hibernation.replan()
        }

        /// ``advance(to:cpu:)`` by `seconds`, then waits for the saver's reading of this instant to land.
        func step(_ seconds: Double, cpu added: [String: Duration]) async throws {
            advance(to: (instant - start + .seconds(seconds)) / .seconds(1), cpu: added)
            let at = instant
            try await until("the reading lands") { hibernation.saverCPU.lastReadingAt == at }
        }

        func evaluations(_ key: String) -> Int {
            tabs[key]?.commands.filter { if case .evaluate = $0 { true } else { false } }.count ?? 0
        }

        /// Lets the probes and readings already started finish.
        func settle() async {
            for _ in 0..<20 { await Task.yield() }
        }

        func until(_ what: String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(await condition(), "\(what) never happened")
        }

        func close() {
            for key in tabs.keys { services.cache.release(key) }
            hibernation.stop()
        }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}
