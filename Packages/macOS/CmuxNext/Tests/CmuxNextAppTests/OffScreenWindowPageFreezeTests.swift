import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Feature `offScreenWindowPageFreeze`: the page a minimized or covered window shows is hidden to the
/// engine at once. A tab that follows no node (a fork before API 37) freezes through the hidden pages' freeze, hidden
/// first (`freezeShownInOffScreenWindow`), with no wait for `freezeSeconds`; the window coming back and an agent's call
/// thaw it in their own turn. A tab that follows its node is hidden by the node and is left alone. The windows' changes
/// come straight from the cache's off-screen notice (`windowDidChangeOnScreen`), as the occlusion checker sends them.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct OffScreenWindowPageFreezeTests {
    @Test func aShownPageInAMinimizedWindowFreezesAtOnceAndThawsWhenItComesBack() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let key = try await rig.showPage("minimized")
        let freezer = try #require(rig.freezers[key])

        rig.setOffScreen(true)
        try await rig.until("the shown page freezes") { rig.hibernation.frozen.contains(key) }
        #expect(freezer.calls == [.shownFreeze], "the shown page froze as a hidden page: \(freezer.calls)")
        #expect(rig.services.cache.phase(of: key) == .mountedVisible, "the window's page left its visible phase")

        rig.setOffScreen(false)
        #expect(!rig.hibernation.frozen.contains(key), "the page stayed frozen in a window on screen")
        #expect(freezer.calls == [.shownFreeze, .frozen(false)], "the window came back: \(freezer.calls)")
    }

    /// An agent's call reaches a live page: the thaw goes out before it, and the page stays awake through the agent's
    /// grace although its window stays off screen.
    @Test func anAgentCallThawsTheFrozenShownPageFirst() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let key = try await rig.showPage("agent")
        let freezer = try #require(rig.freezers[key])
        rig.setOffScreen(true)
        try await rig.until("the shown page freezes") { rig.hibernation.frozen.contains(key) }

        rig.hibernation.noteAgentUse(key)
        #expect(freezer.calls == [.shownFreeze, .frozen(false)], "the agent's call reached a frozen page: \(freezer.calls)")
        rig.hibernation.replan()
        try await Task.sleep(for: .milliseconds(500))
        #expect(freezer.calls == [.shownFreeze, .frozen(false)], "the page froze again under the agent: \(freezer.calls)")
    }

    /// From fork API 37 the window node hides the tab itself: no freeze of the shown page.
    @Test func aPageThatFollowsItsNodeIsNotFrozenByItsWindow() async throws {
        let rig = try Rig(followsTabVisibility: true)
        defer { rig.close() }
        let key = try await rig.showPage("follows")
        #expect(rig.hibernation.tabVisibility.follows(key))
        rig.setOffScreen(true)
        try await Task.sleep(for: .seconds(1))
        #expect(rig.freezers[key]?.calls == [], "a page its node hides was frozen too")
    }

    @Test func withoutTheFeatureAShownPageStaysAwake() async throws {
        let rig = try Rig(feature: false)
        defer { rig.close() }
        let key = try await rig.showPage("off")
        rig.setOffScreen(true)
        try await Task.sleep(for: .seconds(1))
        #expect(rig.freezers[key]?.calls == [], "the window froze its page with the feature off")
    }

    /// The app's cache and hibernation (a 60 min timeout and a 10 min freeze delay, so only the off-screen freeze can
    /// run in the test), one pane in `window`, and the `freezer` and `follower` seams' recorders.
    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let window: NSWindow
        let pane: OccludedWindowDiscardTests.Pane
        let folder: URL
        var keys: [String] = []
        var freezers: [String: Freezer] = [:]
        var followers: [String: BrowserHibernationTabVisibilityTests.Follower] = [:]

        init(feature: Bool = true, followsTabVisibility: Bool = false) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(),
                                             deadlines: services.mainDeadlines, followsTabVisibility: followsTabVisibility)
            window = OccludedWindowDiscardTests.makeWindow(NSRect(x: 100, y: 100, width: 400, height: 300))
            pane = OccludedWindowDiscardTests.Pane(window: window)
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-offscreen-freeze-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            // Every stored property is set before the seams below capture `self`.
            services.cache.hibernation = hibernation
            hibernation.freezesOffScreenShownPages = feature
            hibernation.apply(BrowserHibernationSetting(mode: .minutes(60), freezeSeconds: 600))
            hibernation.freezer = { [weak self] tab in self?.freezers[tab.id.rawValue] }
            hibernation.tabVisibility.follower = { [weak self] tab in self?.followers[tab.id.rawValue] }
            hibernation.start()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        /// A loaded WebKit page, installed as a tab and shown in the pane.
        func showPage(_ name: String) async throws -> String {
            let url = folder.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: url, atomically: true, encoding: .utf8)
            let page = services.cache.webKit.makeWebKitTab()
            page.load(url)
            try await until("\(name) loads") {
                (try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string(name)
            }
            let key = page.id.rawValue
            keys.append(key)
            freezers[key] = Freezer()
            followers[key] = BrowserHibernationTabVisibilityTests.Follower()
            services.cache.install(page, for: key)
            services.cache.present(key, by: pane, presence: .visible)
            try #require(services.cache.phase(of: key) == .mountedVisible)
            return key
        }

        /// The occlusion checker's notice for the pane's window.
        func setOffScreen(_ offScreen: Bool) {
            services.cache.windowDidChangeOnScreen(ObjectIdentifier(window), offScreen: offScreen)
        }

        func until(_ what: String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try #require(await condition(), "\(what) never happened")
        }

        func close() {
            services.cache.removePresenter(pane)
            for key in keys { services.cache.release(key) }
            hibernation.stop()
            window.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Records each freeze and thaw the hibernation asks for.
    @MainActor final class Freezer: BrowserFreezing {
        enum Call: Equatable {
            case frozen(Bool)
            /// ``BrowserFreezing/freezeShownInOffScreenWindow()``.
            case shownFreeze
        }

        private(set) var calls: [Call] = []

        func setFrozen(_ frozen: Bool) -> Bool {
            calls.append(.frozen(frozen))
            return true
        }

        func freezeShownInOffScreenWindow() -> Bool {
            calls.append(.shownFreeze)
            return true
        }
    }
}
