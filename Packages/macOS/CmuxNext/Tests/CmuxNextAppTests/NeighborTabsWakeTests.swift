import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextPages
@testable import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Neighbor tabs, live (`BrowserHibernation` with real WebKit pages): a switch to a neighbor
/// is warm. The page was thawed or restored before the switch, so the show thaws nothing
/// and reloads nothing on the main thread. WebKit pages do not freeze in the app; the
/// `freezer` seam gives them a recorder so the freeze path runs here as for Chromium.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct NeighborTabsWakeTests {
    /// Four hidden, frozen pages; the pane shows b: a and c thaw before any switch, d stays frozen.
    @Test func theShownTabsNeighborsThawAheadOfTheSwitch() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["a", "b", "c", "d"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }

        rig.show(keys[1], order: keys)
        #expect(rig.hibernation.awakeNeighbors == [keys[0], keys[2]])
        #expect(!rig.hibernation.frozen.contains(keys[0]))
        #expect(!rig.hibernation.frozen.contains(keys[2]))
        #expect(rig.hibernation.frozen.contains(keys[3]))
        #expect(rig.recorders[keys[0]]?.calls.last == false)
    }

    /// Ctrl-Tab from b to c: c is already awake (a warm switch, no thaw at show), d becomes a
    /// neighbor and thaws, and a, no longer a neighbor, freezes again after the delay.
    @Test func aSwitchToANeighborIsWarm() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["a", "b", "c", "d", "e"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[1], order: keys)
        let cold = rig.hibernation.coldShows

        rig.show(keys[2], order: keys)
        #expect(rig.hibernation.coldShows == cold, "the switch to a neighbor thawed it on the main thread")
        #expect(rig.hibernation.awakeNeighbors == [keys[1], keys[3]])
        #expect(!rig.hibernation.frozen.contains(keys[3]))
        try await rig.until("the old neighbor freezes again") { rig.hibernation.frozen.contains(keys[0]) }
        #expect(!rig.hibernation.frozen.contains(keys[1]))
    }

    /// A far tab (not a neighbor, not hovered) is still a cold switch: the show thaws it.
    @Test func aSwitchToAFarTabIsCold() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["a", "b", "c", "d", "e"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[0], order: keys)
        let cold = rig.hibernation.coldShows
        rig.show(keys[2], order: keys)
        #expect(rig.hibernation.coldShows == cold + 1)
    }

    /// The pointer on a far tab thaws it before the click; the click is then warm.
    @Test func aHoveredTabThawsBeforeTheClick() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["a", "b", "c", "d", "e"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[0], order: keys)
        rig.hibernation.noteHover(keys[2])
        #expect(!rig.hibernation.frozen.contains(keys[2]))
        #expect(rig.hibernation.exemptions[keys[2]] == .neighbor)
        let cold = rig.hibernation.coldShows
        rig.show(keys[2], order: keys)
        #expect(rig.hibernation.coldShows == cold)
    }

    /// A reorder puts a frozen tab beside the shown one: it thaws at once.
    @Test func aReorderThawsTheNewNeighbor() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["a", "b", "c", "d"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[0], order: keys)
        #expect(rig.hibernation.frozen.contains(keys[2]))
        rig.hibernation.paneDidChange(ObjectIdentifier(rig.pane), order: [keys[0], keys[2], keys[1], keys[3]], selected: keys[0])
        #expect(rig.hibernation.awakeNeighbors == [keys[2], keys[3]])
        #expect(!rig.hibernation.frozen.contains(keys[2]))
    }

    /// A hibernated neighbor restores in the background, so the switch shows a live page.
    @Test func aHibernatedNeighborRestoresInTheBackground() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .minutes(0.000_1), freezeSeconds: nil))
        let keys = try await rig.pages(["a", "b", "c"])
        try await rig.until("every hidden page hibernates") { keys.allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }

        rig.show(keys[0], order: keys)
        try await rig.until("both neighbors restore while hidden") {
            [keys[1], keys[2]].allSatisfy {
                rig.services.cache.phase(of: $0) == .mountedHidden && !(rig.services.cache.browsers[$0]?.tab is HibernatedBrowserTab)
            }
        }
        #expect(rig.hibernation.prewarmedCount >= 2)
    }

    /// A restore loads the page again. A page the person hibernated (Hibernate Tab) never restores
    /// as a neighbor or a hovered tab, whatever the setting, and with no `browser.hibernation`
    /// written no hibernated page restores early: only a show or a wake brings it back.
    @Test func aPageThePersonHibernatedRestoresOnlyWhenShownOrWoken() async throws {
        let rig = try Rig(freezes: false)
        defer { rig.close() }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil, discardsAutomatically: false))
        let keys = try await rig.pages(["a", "b", "c", "d", "e"])
        let asleep = Array(keys.dropFirst())
        for key in asleep { #expect(rig.hibernation.hibernateNow(key) == nil) }
        try await rig.until("the person's pages hibernate") { asleep.allSatisfy { rig.services.cache.phase(of: $0) == .hibernated } }

        // a shows: b and e (the strip wraps) become neighbors; c, a far tab, is hovered past the dwell.
        rig.show(keys[0], order: keys)
        #expect(rig.hibernation.awakeNeighbors == [keys[1], keys[4]])
        rig.hibernation.noteHover(keys[2])
        try await Task.sleep(for: BrowserHibernation.hoverDwellDelay * 3)
        for key in asleep {
            #expect(rig.services.cache.phase(of: key) == .hibernated, "a prewarm reloaded a page nobody asked for")
        }
        #expect(!rig.hibernation.mayPrewarmRestore(keys[1]))

        // A timeout written to cmux.json: pages the person hibernated still wait for a show.
        rig.hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil))
        rig.hibernation.noteHover(keys[2])
        try await Task.sleep(for: BrowserHibernation.hoverDwellDelay * 3)
        #expect(rig.services.cache.phase(of: keys[2]) == .hibernated)
        #expect(!rig.hibernation.mayPrewarmRestore(keys[2]))
        #expect(rig.hibernation.mayPrewarmRestore(keys[0]), "an opted-in timeout's own discards may prewarm")

        // Shown, or woken: it restores.
        rig.show(keys[3], order: keys)
        try await rig.until("the shown page restores") { !(rig.services.cache.browsers[keys[3]]?.tab is HibernatedBrowserTab) }
        #expect(rig.hibernation.wake(keys[2], by: .person) == .started)
        try await rig.until("the woken page restores") { !(rig.services.cache.browsers[keys[2]]?.tab is HibernatedBrowserTab) }
        #expect(rig.services.cache.phase(of: keys[1]) == .hibernated)
    }

    /// Memory pressure and Energy Saver shrink the neighbor set to nothing; a policy change that
    /// leaves the saver as it was (the power source) changes nothing.
    @Test func pressureAndEnergySaverKeepNoNeighborAwake() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["a", "b", "c"])
        rig.show(keys[1], order: keys)
        #expect(rig.hibernation.awakeNeighbors.count == 2)
        rig.hibernation.pressureDidChange(.warning)
        #expect(rig.hibernation.awakeNeighbors.isEmpty)
        rig.hibernation.pressureDidChange(.normal)
        #expect(rig.hibernation.awakeNeighbors.count == 2)
        rig.energy.update(EnergyPolicy(onBattery: true))
        #expect(rig.hibernation.awakeNeighbors.count == 2, "a policy change without the saver dropped the neighbors")
        rig.energy.update(EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(rig.hibernation.energySaver)
        #expect(rig.hibernation.neighborRadius == 0)
        #expect(rig.hibernation.awakeNeighbors.isEmpty, "Energy Saver kept neighbors awake")
        rig.energy.update(.normal)
        #expect(rig.hibernation.awakeNeighbors.count == 2, "the neighbors did not wake again after the saver")
    }

    /// The saver reaches the cmux pages' lifecycle too (a shorter recently visible window), and so does
    /// Low Power Mode while the `energySaver` feature is off (the policy's fallback).
    @Test func energySaverReachesThePageLifecycle() throws {
        let rig = try Rig()
        defer { rig.close() }
        let lifecycle = PageLifecycle(deadlines: rig.services.mainDeadlines)
        rig.services.cache.pageLifecycle = lifecycle
        defer { rig.services.cache.pageLifecycle = nil }
        rig.energy.update(EnergyPolicy(saverReason: .setting))
        #expect(lifecycle.conditions.energySaver, "the page lifecycle did not take the saver")
        rig.energy.update(.normal)
        #expect(!lifecycle.conditions.energySaver, "the page lifecycle kept the saver after it ended")
        rig.energy.update(EnergyPolicy(lowPowerFallback: true))
        #expect(lifecycle.conditions.energySaver, "the page lifecycle ignored Low Power Mode with the feature off")
    }

    @Test func zeroTurnsItOff() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var setting = rig.hibernation.setting
        setting.neighborRadius = 0
        rig.hibernation.apply(setting)
        let keys = try await rig.pages(["a", "b", "c"])
        rig.show(keys[1], order: keys)
        #expect(rig.hibernation.awakeNeighbors.isEmpty)
    }

    /// Intent prewarm (`intentPrewarmHover`) with the hibernation as its warmer: a frozen hidden
    /// page is cold, a strip hover reaches the service through `noteHover`, its dwell thaws the page, and the
    /// switch that shows it is the commit (used, not cancelled). Neighbors are off, so only the dwell thaws.
    @Test func theHoverDwellPrewarmThawsAFrozenTabAndTheSwitchUsesIt() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var setting = rig.hibernation.setting
        setting.neighborRadius = 0
        rig.hibernation.apply(setting)
        let keys = try await rig.pages(["a", "b", "c"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[0], order: keys)
        #expect(!rig.hibernation.isCold(keys[0]), "the shown page has nothing to prewarm")
        #expect(rig.hibernation.isCold(keys[2]))
        #expect(!rig.hibernation.isCold("not-a-page"))

        let deadlines = MainDeadlineRig()
        let service = IntentPrewarmService<String>(
            warmer: rig.hibernation, memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
            dwellTimer: MainDeadline(owner: "IntentPrewarm.hoverDwell", workClass: .background, scheduler: deadlines.deadlines),
            pressStart: MainDeadline(owner: "IntentPrewarm.pressStart", workClass: .background, scheduler: deadlines.deadlines))
        rig.hibernation.intentPrewarm = (service, rig.services.energyMonitor.follow { _ in })

        rig.hibernation.noteHover(keys[2])
        #expect(service.isDwelling)
        #expect(rig.hibernation.frozen.contains(keys[2]), "nothing thaws before the dwell")
        deadlines.fireAndRun()
        #expect(!rig.hibernation.frozen.contains(keys[2]))
        #expect(service.queue.held == [keys[2]])
        #expect(service.counters.started[.hoverDwell] == 1)

        rig.show(keys[2], order: keys)
        #expect(service.queue.held.isEmpty)
        #expect(service.counters.used == 1)
    }

    // MARK: Rig

    /// Records `setFrozen` calls for one page.
    @MainActor final class Recorder: BrowserFreezing {
        var calls: [Bool] = []
        func setFrozen(_ frozen: Bool) -> Bool { calls.append(frozen); return true }
    }

    /// The app's tab content cache and hibernation with one pane; hidden pages freeze at once.
    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let energy = EnergyPolicySource()
        let pane = Pane()
        let folder: URL
        var keys: [String] = []
        var recorders: [String: Recorder] = [:]
        private var shown: String?

        /// - Parameter audible: The pages' sound history (`recentlyAudibleProtection` on); nil leaves it off.
        init(freezes: Bool = true, audible: AudibleHistory? = nil) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines, energy: energy, audible: audible)
            services.cache.hibernation = hibernation
            hibernation.apply(BrowserHibernationSetting(mode: .off, freezeSeconds: freezes ? 0.05 : nil))
            hibernation.start()
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-neighbor-tabs-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            hibernation.freezer = { [weak self] tab in self?.recorders[tab.id.rawValue] }
        }

        /// Loaded pages, installed as tabs, each shown once then hidden.
        func pages(_ names: [String]) async throws -> [String] {
            var made: [String] = []
            for name in names {
                let url = folder.appendingPathComponent("\(name).html")
                try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: url, atomically: true, encoding: .utf8)
                let page = services.cache.webKit.makeWebKitTab()
                page.load(url)
                try await until("\(name) loads") {
                    (try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string(name)
                }
                let key = page.id.rawValue
                recorders[key] = Recorder()
                keys.append(key)
                services.cache.install(page, for: key)
                services.cache.present(key, by: pane, presence: .visible)
                services.cache.withdraw(key, by: pane)
                try #require(services.cache.phase(of: key) == .mountedHidden)
                made.append(key)
            }
            return made
        }

        /// The pane switches to `key` (as `PaneController.showSelected` does) and reports its order.
        func show(_ key: String, order: [String]) {
            if let shown, shown != key { services.cache.withdraw(shown, by: pane) }
            services.cache.present(key, by: pane, presence: .visible)
            shown = key
            hibernation.paneDidChange(ObjectIdentifier(pane), order: order, selected: key)
        }

        func until(_ what: String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try #require(await condition(), "\(what) never happened")
        }

        func close() {
            hibernation.paneDidGo(ObjectIdentifier(pane))
            for key in keys { services.cache.release(key) }
            hibernation.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}
