import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextHibernation
@testable import CmuxNextSettings
import Foundation
import Testing

/// ``BrowserHibernation`` reads a frozen page's memory only behind `frozenGrowthDiscard`, at its
/// freeze and at one-shot deadlines that end when the page thaws, and discards a growing page with
/// the frozen hidden pages of its `window.opener` group (`FrozenGrowthRule`, p07-memory.md task 020).
/// WebKit pages do not freeze in the app; the `freezer` seam gives them a recorder so the freeze
/// path runs here as for Chromium.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct BrowserHibernationFrozenGrowthTests {
    static let mb: UInt64 = 1 << 20

    static func alone(_ key: String, _ megabytes: UInt64) -> PageMemoryReading {
        PageMemoryReading(bytes: megabytes * mb, sharers: [key])
    }

    private func makeHibernation(_ services: AppServices, sample: [String: PageMemoryReading] = [:]) -> BrowserHibernation {
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
        hibernation.measureMemory = { sample }
        return hibernation
    }

    private func makeServices() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @Test func withTheFeatureOffAFrozenPageIsNeverRead() {
        let services = makeServices()
        let hibernation = makeHibernation(services)
        hibernation.trackGrowth("a")
        #expect(hibernation.frozenGrowth.pages.isEmpty)
        #expect(!hibernation.growthDeadline.isScheduled, "the feature is off and a reading was armed")
        withExtendedLifetime((services, hibernation)) {}
    }

    /// `browser.hibernation: "off"` disables it completely: no frozen page is read, and turning it
    /// off ends the readings of the pages already frozen.
    @Test func withHibernationOffAFrozenPageIsNeverRead() {
        let services = makeServices()
        let hibernation = makeHibernation(services)
        hibernation.discardsGrowingFrozenPages = true
        hibernation.trackGrowth("a")
        #expect(hibernation.growthDeadline.isScheduled)
        hibernation.apply(BrowserHibernationSetting(mode: .off))
        #expect(hibernation.frozenGrowth.pages.isEmpty, "a page frozen before the switch is still read")
        #expect(!hibernation.growthDeadline.isScheduled)
        hibernation.trackGrowth("b")
        #expect(hibernation.frozenGrowth.pages.isEmpty, "a page frozen with hibernation off is read")
        hibernation.stop()
        withExtendedLifetime((services, hibernation)) {}
    }

    @Test func aFrozenPageArmsOneDeadlineThatItsThawDrops() {
        let services = makeServices()
        let hibernation = makeHibernation(services)
        hibernation.discardsGrowingFrozenPages = true
        hibernation.trackGrowth("a")
        #expect(hibernation.growthDeadline.isScheduled)
        hibernation.untrackGrowth("a")
        #expect(!hibernation.growthDeadline.isScheduled, "a thawed page kept its reading deadline")
        hibernation.stop()
        withExtendedLifetime((services, hibernation)) {}
    }

    /// "Record bytes at freeze": with no fresh reading, the freeze takes one sample and its reading
    /// is the baseline, long before the first one-shot wakeup.
    @Test func aFreezeWithNoFreshReadingSamplesOnce() async throws {
        let services = makeServices()
        var samples = 0
        let hibernation = makeHibernation(services)
        hibernation.measureMemory = {
            samples += 1
            return ["a": Self.alone("a", 120), "b": Self.alone("b", 80)]
        }
        hibernation.discardsGrowingFrozenPages = true
        hibernation.trackGrowth("a")
        try await Self.until("the freeze's sample lands") { hibernation.frozenGrowth.pages["a"]?.baseline != nil }
        #expect(hibernation.frozenGrowth.pages["a"]?.baseline == 120 * Self.mb)
        #expect(hibernation.frozenGrowth.pages["a"]?.wakeups == 0, "the baseline waited for a one-shot wakeup")
        hibernation.trackGrowth("b")
        #expect(samples == 1, "a freeze within a fresh sample sampled again")
        #expect(hibernation.frozenGrowth.pages["b"]?.baseline == 80 * Self.mb)
        hibernation.stop()
        withExtendedLifetime((services, hibernation)) {}
    }

    @Test func aFreshReadingAtTheFreezeIsTheBaseline() {
        let services = makeServices()
        let hibernation = makeHibernation(services)
        hibernation.discardsGrowingFrozenPages = true
        hibernation.memoryReadings.land(["a": Self.alone("a", 100)], at: .now)
        hibernation.trackGrowth("a")
        #expect(hibernation.frozenGrowth.pages["a"]?.baseline == 100 * Self.mb)
        hibernation.stop()
        withExtendedLifetime((services, hibernation)) {}
    }

    /// No periodic sampling: after its third one-shot reading a page that is still frozen arms no
    /// deadline, and a later reading (the Task Manager's) arms none either.
    @Test func afterTheThirdWakeupNoDeadlineIsLeft() throws {
        let services = makeServices()
        let hibernation = makeHibernation(services)
        hibernation.discardsGrowingFrozenPages = true
        hibernation.memoryReadings.land(["a": Self.alone("a", 100)], at: .now)
        hibernation.trackGrowth("a")
        let frozenAt = try #require(hibernation.frozenGrowth.pages["a"]?.frozenAt)
        for delay in FrozenGrowthRule.sampleDelays {
            #expect(hibernation.growthDeadline.isScheduled)
            hibernation.readFrozenGrowth(at: frozenAt + delay)
        }
        #expect(hibernation.frozenGrowth.pages["a"]?.wakeups == 3)
        #expect(!hibernation.growthDeadline.isScheduled, "a frozen page kept a reading deadline after its three")
        hibernation.noteMemory(["a": Self.alone("a", 100)])
        #expect(!hibernation.growthDeadline.isScheduled, "a reading armed a deadline")
        hibernation.stop()
        withExtendedLifetime((services, hibernation)) {}
    }

    // MARK: Live pages

    /// The popup grew past its threshold: it and its frozen opener hibernate together; the member
    /// that shows stays, and so does a frozen page outside the group.
    @Test func theOpenerAndItsPopupHibernateTogether() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["opener", "popup", "outsider"])
        let shown = try await rig.pages(["shown"], hide: false)[0]
        let (opener, popup, outsider) = (keys[0], keys[1], keys[2])
        let family: Set<String> = [opener, popup, shown]
        rig.hibernation.openerGroup = { family.contains($0) ? family : [$0] }
        try await rig.until("every hidden page freezes with a baseline") {
            keys.allSatisfy { rig.hibernation.frozenGrowth.pages[$0]?.baseline != nil }
        }

        rig.hibernation.noteMemory([popup: Self.alone(popup, 200), opener: Self.alone(opener, 100),
                                    outsider: Self.alone(outsider, 100), shown: Self.alone(shown, 900)])
        try await rig.until("the opener and the popup hibernate") { rig.isHibernated(opener) && rig.isHibernated(popup) }
        #expect(!rig.isHibernated(shown), "the shown member went")
        #expect(!rig.isHibernated(outsider), "a page outside the group went")
        #expect(rig.hibernation.frozen.contains(outsider))
    }

    /// A member a pre-probe fact keeps (a download it runs) stays frozen and read; the next readings
    /// of the same growth plan nothing again, so no member thaws for a probe on every sample.
    @Test func aKeptGrowingPageIsNotPlannedOnEveryReading() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let keys = try await rig.pages(["downloads"])
        let key = keys[0]
        rig.downloading = [key]
        try await rig.until("the page freezes with a baseline") { rig.hibernation.frozenGrowth.pages[key]?.baseline != nil }
        for _ in 0..<3 { rig.hibernation.noteMemory([key: Self.alone(key, 400)]) }
        #expect(rig.hibernation.exemptions[key] == .downloading)
        #expect(rig.hibernation.frozen.contains(key), "the kept page was thawed for a probe")
        #expect(rig.hibernation.frozenGrowth.pages[key]?.baseline == 400 * Self.mb, "the growth was not taken")
        #expect(rig.hibernation.probing.isEmpty)
    }

    // MARK: The opener group

    /// The group is the pages script can reach through `window.opener` (an engine-made tab), not the
    /// tab strip's placement openers: a user switch does not split it, and a `noopener` link tab is
    /// not in it.
    @Test func theOpenerGroupIsTheWindowOpenerLinks() {
        let services = makeServices()
        let cache = services.cache
        let opener = cache.webKit.makeWebKitTab(), popup = cache.webKit.makeWebKitTab(), link = cache.webKit.makeWebKitTab()
        let keys = [opener, popup, link].map(\.id.rawValue)
        for (page, key) in zip([opener, popup, link], keys) { _ = cache.install(page, for: key) }
        defer { for key in keys { cache.release(key) } }
        cache.pageRequests.scriptOpeners.record(child: popup, opener: opener)
        cache.pageRequests.openers.forgetAll()
        #expect(services.openerGroup(of: keys[1]) == [keys[0], keys[1]])
        #expect(services.openerGroup(of: keys[0]) == [keys[0], keys[1]])
        #expect(services.openerGroup(of: keys[2]) == [keys[2]], "a noopener link tab is in the group")
    }

    static func until(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(await condition(), "\(what) never happened")
    }

    // MARK: Rig

    @MainActor final class Recorder: BrowserFreezing {
        func setFrozen(_ frozen: Bool) -> Bool { true }
    }

    /// The app's tab content cache and hibernation with one pane: hidden pages freeze at once, never
    /// hibernate for the timeout, and every page reads 100 MB alone in its process until a test
    /// notes more.
    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let pane = Pane()
        let folder: URL
        var keys: [String] = []
        var recorders: [String: Recorder] = [:]
        var downloading: Set<String> = []

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-frozen-growth-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            services.cache.hibernation = hibernation
            hibernation.discardsGrowingFrozenPages = true
            hibernation.measureMemory = { [weak self] in
                (self?.keys ?? []).reduce(into: [String: PageMemoryReading]()) { $0[$1] = BrowserHibernationFrozenGrowthTests.alone($1, 100) }
            }
            hibernation.isDownloading = { [weak self] in self?.downloading.contains($0) ?? false }
            hibernation.apply(BrowserHibernationSetting(mode: .minutes(600), freezeSeconds: 0.05))
            hibernation.start()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            hibernation.freezer = { [weak self] tab in self?.recorders[tab.id.rawValue] }
        }

        /// Loaded pages, installed as tabs, each shown once then hidden (`hide` false: left shown).
        func pages(_ names: [String], hide: Bool = true) async throws -> [String] {
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
                if hide {
                    services.cache.withdraw(key, by: pane)
                    try #require(services.cache.phase(of: key) == .mountedHidden)
                }
                made.append(key)
            }
            return made
        }

        func isHibernated(_ key: String) -> Bool { services.cache.browsers[key]?.tab is HibernatedBrowserTab }

        func until(_ what: String, _ condition: () async -> Bool) async throws {
            try await BrowserHibernationFrozenGrowthTests.until(what, condition)
        }

        func close() {
            for key in keys { services.cache.release(key) }
            hibernation.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}
