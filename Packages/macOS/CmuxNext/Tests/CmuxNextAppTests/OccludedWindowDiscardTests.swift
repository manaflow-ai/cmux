import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// Minimized, other-Space or covered windows count as hidden (p07-memory-021, Chrome's
/// `Visibility::OCCLUDED`): a page such a window shows gets a hidden clock and is discarded after the
/// timeout as any hidden page; back on screen is a show. The rule is Chrome's
/// `WebContentsOcclusionCheckerMac` (web_contents_occlusion_checker_mac.mm). The windows' facts come
/// from a fake draw policy (`Rig.facts`), so nothing here needs a screen.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct OccludedWindowDiscardTests {
    // MARK: The rule

    @Test func aWindowInsideAnOpaqueWindowInFrontIsCovered() {
        let (front, back) = (Self.window(1, x: 0, width: 1000, active: true), Self.window(2, x: 100, width: 400))
        #expect(WindowOcclusionRule().isOccluded(back, frontToBack: [front, back]))
        #expect(!WindowOcclusionRule().isOccluded(front, frontToBack: [front, back]))
    }

    /// No region union: two windows side by side may let the corners of the one behind show.
    @Test func aPartialCoverOrTwoSideBySideDoNotCover() {
        let back = Self.window(3, x: 100, width: 400)
        let left = Self.window(1, x: 0, width: 300), right = Self.window(2, x: 300, width: 300)
        #expect(!WindowOcclusionRule().isOccluded(back, frontToBack: [left, right, back]))
    }

    @Test func aGlassOrMovingWindowCoversNothing() {
        var glass = Self.window(1, x: 0, width: 1000)
        glass.paintsOpaque = false
        let back = Self.window(2, x: 100, width: 400)
        #expect(!WindowOcclusionRule().isOccluded(back, frontToBack: [glass, back]))
        let front = Self.window(1, x: 0, width: 1000)
        #expect(!WindowOcclusionRule(moving: front.id).isOccluded(back, frontToBack: [front, back]))
    }

    /// `orderedWindows` lags behind a window that just became active (Cmd-` cycling).
    @Test func theActiveWindowIsNeverCoveredByAnInactiveOne() {
        let inactive = Self.window(1, x: 0, width: 1000)
        let active = Self.window(2, x: 100, width: 400, active: true)
        #expect(!WindowOcclusionRule().isOccluded(active, frontToBack: [inactive, active]))
        // An inactive window listed before the active one that covers it is still covered.
        let behind = Self.window(3, x: 100, width: 400)
        let cover = Self.window(4, x: 0, width: 1000, active: true)
        #expect(WindowOcclusionRule().isOccluded(behind, frontToBack: [behind, cover]))
    }

    @Test func aMinimizedOrOtherSpaceWindowOrSleepingDisplaysAreOffScreen() {
        var minimized = Self.window(1, x: 0, width: 400)
        minimized.systemVisible = false
        #expect(WindowOcclusionRule().isOccluded(minimized, frontToBack: [minimized]))
        let shown = Self.window(2, x: 0, width: 400)
        #expect(!WindowOcclusionRule().isOccluded(shown, frontToBack: [shown]))
        #expect(WindowOcclusionRule(displaysAsleep: true).isOccluded(shown, frontToBack: [shown]))
    }

    /// An off-screen window's panes keep no neighbors awake; back on screen they do again.
    @Test func anOffScreenPaneKeepsNoNeighborsAwake() {
        let (pane, other) = (ObjectIdentifier(Marker.all[1]), ObjectIdentifier(Marker.all[2]))
        var tabs = NeighborTabs()
        tabs.set(pane, order: ["a", "b", "c"], selected: "b")
        tabs.set(other, order: ["x", "y", "z"], selected: "y")
        tabs.setOffScreen(true, pane: pane)
        #expect(tabs.awake(radius: 1) == ["x", "z"])
        tabs.setOffScreen(false, pane: pane)
        #expect(tabs.awake(radius: 1) == ["a", "c", "x", "z"])
    }

    // MARK: The checker

    /// Events only: after the first pass nothing reads a window again until a window event.
    @Test func theCheckerNeverPollsOcclusionState() async throws {
        let rig = try Rig()
        defer { rig.close() }
        try await rig.until("the first pass ran") { rig.checker.passes == 1 }
        let reads = rig.factReads
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.checker.passes == 1, "the checker ran a pass with no window event")
        #expect(rig.factReads == reads, "the checker read a window's state with no window event")
        rig.post(NSWindow.didChangeOcclusionStateNotification, rig.window)
        rig.post(NSWindow.didResignMainNotification, rig.window)
        try await rig.until("one pass for both events") { rig.checker.passes == 2 }
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.checker.passes == 2, "two events in one turn ran two passes")
    }

    // MARK: Pages

    @Test func aPageInAMinimizedWindowIsDueAfterTheTimeoutNeverWhileVisible() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let key = try await rig.showPage("minimized")
        try await Task.sleep(for: .seconds(2))
        #expect(rig.services.cache.phase(of: key) == .mountedVisible, "a page on screen left its visible phase")
        #expect(!rig.isHibernated(key), "a page on screen was discarded")

        rig.minimize()
        try await rig.until("the page hides with its window") { rig.services.cache.phase(of: key) == .mountedHidden }
        try await rig.until("the page is discarded after the timeout") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == nil)
        #expect(rig.isHibernated(key))

        rig.restore()
        try await rig.until("the page shows again with its window") {
            [.restoring, .mountedVisible].contains(rig.services.cache.phase(of: key))
        }
    }

    @Test func aPageInAWindowCoveredByAnotherCmuxWindowCountsAsHidden() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let key = try await rig.showPage("covered")
        rig.cover()
        try await rig.until("the covered page hides") { rig.services.cache.phase(of: key) == .mountedHidden }
        try await rig.until("the covered page is discarded") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.isHibernated(key))

        rig.uncover()
        try await rig.until("the page shows when its window is uncovered") {
            [.restoring, .mountedVisible].contains(rig.services.cache.phase(of: key))
        }
    }

    /// Without the feature (no checker) a minimized window's page stays as it is.
    @Test func withoutTheCheckerAMinimizedWindowsPageStays() async throws {
        let rig = try Rig(follows: false)
        defer { rig.close() }
        let key = try await rig.showPage("unfollowed")
        rig.minimize()
        try await Task.sleep(for: .seconds(2))
        #expect(rig.services.cache.phase(of: key) == .mountedVisible)
    }

    // MARK: Rig

    static func window(_ id: Int, x: CGFloat, width: CGFloat, active: Bool = false) -> WindowOcclusionFacts {
        WindowOcclusionFacts(id: ObjectIdentifier(Marker.all[id]), frame: CGRect(x: x, y: 0, width: width, height: 600), isActive: active)
    }

    /// Distinct identities for the pure rule's windows.
    final class Marker {
        static let all = (0..<8).map { _ in Marker() }
    }

    /// The fake draw policy: each window's facts, set by the test, and how often the checker read one.
    @MainActor final class FakeDrawPolicy {
        var facts: [ObjectIdentifier: WindowOcclusionFacts] = [:]
        private(set) var reads = 0

        func read(_ window: NSWindow) -> WindowOcclusionFacts {
            reads += 1
            return facts[ObjectIdentifier(window)] ?? WindowDrawPolicy.occlusionFacts(of: window)
        }
    }

    /// The app's cache and hibernation (a 0.6 s timeout, no freeze, no neighbors), one pane in
    /// `window`, a second cmux window `coverWindow` that can cover it, and the checker with the fake
    /// draw policy's facts.
    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let window: NSWindow
        let coverWindow: NSWindow
        let center = NotificationCenter()
        let policy = FakeDrawPolicy()
        let checker: WindowOcclusionChecker
        let pane: Pane
        let folder: URL
        var keys: [String] = []
        var factReads: Int { policy.reads }

        init(follows: Bool = true) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), lowPower: LowPowerMode(enabled: false))
            services.cache.hibernation = hibernation
            hibernation.apply(BrowserHibernationSetting(mode: .minutes(0.01), freezeSeconds: nil, neighborRadius: 0))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            let coverWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled],
                                       backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            coverWindow.isReleasedWhenClosed = false
            self.window = window
            self.coverWindow = coverWindow
            pane = Pane(window: window)
            policy.facts[ObjectIdentifier(window)] = WindowOcclusionFacts(id: ObjectIdentifier(window), frame: window.frame, isActive: true)
            policy.facts[ObjectIdentifier(coverWindow)] = WindowOcclusionFacts(id: ObjectIdentifier(coverWindow), frame: coverWindow.frame,
                                                                              isVisible: false, systemVisible: false)
            checker = WindowOcclusionChecker(windows: { return [window, coverWindow] }, orderedWindows: { return [coverWindow, window] },
                                             facts: { [policy] in policy.read($0) }, drawsWhenOccluded: false,
                                             center: center, workspaceCenter: NotificationCenter())
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-occluded-discard-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            hibernation.start()
            if follows { hibernation.follow(checker) } else { checker.start() }
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
            services.cache.install(page, for: key)
            services.cache.present(key, by: pane, presence: .visible)
            try #require(services.cache.phase(of: key) == .mountedVisible)
            return key
        }

        func minimize() {
            update(window) { $0.isVisible = false; $0.isMiniaturized = true; $0.systemVisible = false; $0.isActive = false }
        }

        func restore() {
            update(window) { $0.isVisible = true; $0.isMiniaturized = false; $0.systemVisible = true; $0.isActive = true }
        }

        /// The other cmux window comes in front of the pane's window and contains it. AppKit still
        /// calls the pane's window visible: only the checker's own rule sees the cover.
        func cover() {
            update(window) { $0.isActive = false }
            policy.facts[ObjectIdentifier(coverWindow)]?.isActive = true
            update(coverWindow) { $0.isVisible = true; $0.systemVisible = true }
            post(NSWindow.didBecomeMainNotification, coverWindow)
        }

        func uncover() {
            update(coverWindow) { $0.isVisible = false; $0.systemVisible = false; $0.isActive = false }
            policy.facts[ObjectIdentifier(window)]?.isActive = true
            post(NSWindow.didBecomeMainNotification, window)
        }

        private func update(_ target: NSWindow, _ change: (inout WindowOcclusionFacts) -> Void) {
            guard var value = policy.facts[ObjectIdentifier(target)] else { return }
            change(&value)
            policy.facts[ObjectIdentifier(target)] = value
            post(NSWindow.didChangeOcclusionStateNotification, target)
        }

        func post(_ name: Notification.Name, _ target: NSWindow) { center.post(name: name, object: target) }

        func isHibernated(_ key: String) -> Bool { services.cache.browsers[key]?.tab is HibernatedBrowserTab }
        func exemption(_ key: String) -> HibernationPlanner.Exemption? { hibernation.exemptions[key] }

        func until(_ what: @autoclosure () -> String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try #require(await condition(), "\(what()) never happened")
        }

        func close() {
            services.cache.removePresenter(pane)
            for key in keys { services.cache.release(key) }
            checker.stop()
            hibernation.stop()
            window.close()
            coverWindow.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @MainActor final class Pane: SurfacePresenter {
        let window: NSWindow
        init(window: NSWindow) { self.window = window }
        var presentingWindow: NSWindow? { window }
        func surfaceWasDisplaced(_ key: String) {}
    }
}
