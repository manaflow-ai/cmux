import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Minimized, other-Space or covered windows count as hidden (Chrome's
/// `Visibility::OCCLUDED`). The rule is Chrome's `WebContentsOcclusionCheckerMac`
/// (web_contents_occlusion_checker_mac.mm). The page a pane shows in an off-screen window gets a hidden
/// clock but stays shown, and the discarder keeps it as its window's active tab (`kActiveTab`,
/// discard_eligibility_policy.cc); the tabs beside it lose their neighbor protection and are
/// discarded after the timeout. Back on screen, they are neighbors again. The windows' facts come
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

    /// A Chromium page window is a child of its cmux window, ordered above it and key while the page
    /// has focus; with the parent's frame (HTML5 fullscreen) it still does not cover its parent.
    @Test func aChildWindowNeverCoversItsParent() {
        let parent = Self.window(1, x: 0, width: 1000)
        var page = Self.window(2, x: 0, width: 1000, active: true)
        page.ancestors = [parent.id]
        #expect(!WindowOcclusionRule().isOccluded(parent, frontToBack: [page, parent]))
        var grandchild = Self.window(3, x: 0, width: 1000, active: true)
        grandchild.ancestors = [page.id, parent.id]
        #expect(!WindowOcclusionRule().isOccluded(parent, frontToBack: [grandchild, page, parent]))
        // Another window's child still covers.
        let other = Self.window(4, x: 100, width: 400)
        #expect(WindowOcclusionRule().isOccluded(other, frontToBack: [page, parent, other]))
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

    @Test func aMinimizedOrOtherSpaceWindowOrSleepingDisplaysOrAHiddenAppAreOffScreen() {
        var minimized = Self.window(1, x: 0, width: 400)
        minimized.systemVisible = false
        #expect(WindowOcclusionRule().isOccluded(minimized, frontToBack: [minimized]))
        let shown = Self.window(2, x: 0, width: 400)
        #expect(!WindowOcclusionRule().isOccluded(shown, frontToBack: [shown]))
        #expect(WindowOcclusionRule(displaysAsleep: true).isOccluded(shown, frontToBack: [shown]))
        #expect(WindowOcclusionRule(appHidden: true).isOccluded(shown, frontToBack: [shown]))
    }

    /// The shown page of an off-screen window is Chrome's active tab: kept from the timeout and from
    /// memory pressure, never from the person's own Hibernate Tab.
    @Test func theActiveTabRuleKeepsTheShownPageFromTheTimeoutAndPressure() {
        var shown = ContentDiscardPlanner.Candidate(key: "shown", hiddenFor: 3600)
        shown.isActiveTab = true
        let setting = BrowserHibernationSetting(mode: .minutes(1))
        let planner = ContentDiscardPlanner()
        #expect(planner.eligibility(of: shown, setting: setting, for: .proactive).reason == .activeTab)
        #expect(planner.eligibility(of: shown, setting: setting, for: .urgent).result == .protected)
        #expect(HibernationPlanner.hibernateTabRefusal(shown, setting: setting) == nil)
        #expect(HibernationPlanner.plan(setting, pressure: .critical, candidates: [shown]).due.isEmpty)
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

    /// A window the checker does not track (onboarding, a debug window) covers a tracked one; when
    /// it is moved away (a programmatic move: no `willMove`), its own move ends the cover.
    @Test func anUntrackedWindowThatMovesAwayUncovers() async throws {
        let rig = CheckerRig()
        defer { rig.stop() }
        rig.policy.facts[ObjectIdentifier(rig.other)] = WindowOcclusionFacts(
            id: ObjectIdentifier(rig.other), frame: CGRect(x: 0, y: 0, width: 1000, height: 800), isActive: true)
        rig.checker.start()
        try await rig.until("the covered window goes off screen") { rig.changes == [CheckerRig.Change(rig.tracked, true)] }
        rig.policy.facts[ObjectIdentifier(rig.other)]?.frame = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        rig.post(NSWindow.didMoveNotification, rig.other)
        try await rig.until("it comes back when the cover moves away") { rig.changes.last == CheckerRig.Change(rig.tracked, false) }
    }

    /// A resize with no live resize (a tiling or scripted resize) is an event too.
    @Test func aProgrammaticResizeOfAnyWindowStartsAPass() async throws {
        let rig = CheckerRig()
        defer { rig.stop() }
        rig.policy.facts[ObjectIdentifier(rig.other)] = WindowOcclusionFacts(
            id: ObjectIdentifier(rig.other), frame: CGRect(x: 0, y: 0, width: 1000, height: 800), isActive: true)
        rig.checker.start()
        try await rig.until("the covered window goes off screen") { rig.changes == [CheckerRig.Change(rig.tracked, true)] }
        rig.policy.facts[ObjectIdentifier(rig.other)]?.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        rig.post(NSWindow.didResizeNotification, rig.other)
        try await rig.until("the shrunk cover uncovers") { rig.changes.last == CheckerRig.Change(rig.tracked, false) }
    }

    /// `WindowActivation` orders a covered window front without the keys (`.bringForward`, a
    /// background deep link): no notification fires, the reorder report starts the pass.
    @Test func aReorderWithoutAKeyChangeStartsAPass() async throws {
        let rig = CheckerRig()
        defer { rig.stop() }
        rig.policy.facts[ObjectIdentifier(rig.other)] = WindowOcclusionFacts(
            id: ObjectIdentifier(rig.other), frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        rig.checker.start()
        try await rig.until("the covered window goes off screen") { rig.changes == [CheckerRig.Change(rig.tracked, true)] }
        // The cover is not active (the app is in the background), so `orderedWindows` is current.
        rig.order = { [rig] in [rig.tracked, rig.other] }
        rig.checker.windowsDidReorder()
        try await rig.until("the window ordered front is on screen") { rig.changes.last == CheckerRig.Change(rig.tracked, false) }
    }

    /// Cmd-H orders every window out: none comes back on screen while the app is hidden, and an
    /// uncovered one goes off screen.
    @Test func hidingTheAppKeepsEveryWindowOffScreen() async throws {
        let rig = CheckerRig()
        defer { rig.stop() }
        rig.checker.start()
        try await rig.until("the first pass ran") { rig.checker.passes == 1 }
        #expect(rig.changes.isEmpty)
        rig.appHidden = true
        for window in [rig.tracked, rig.other] {
            rig.policy.facts[ObjectIdentifier(window)]?.isVisible = false
            rig.policy.facts[ObjectIdentifier(window)]?.systemVisible = false
        }
        rig.center.post(name: NSApplication.didHideNotification, object: nil)
        try await rig.until("the hidden app's window goes off screen") { rig.changes == [CheckerRig.Change(rig.tracked, true)] }
        rig.post(NSWindow.didChangeOcclusionStateNotification, rig.tracked)
        try await rig.until("a second pass ran") { rig.checker.passes == 3 }
        #expect(rig.changes == [CheckerRig.Change(rig.tracked, true)], "a window came back on screen in a hidden app")
        rig.appHidden = false
        rig.policy.facts[ObjectIdentifier(rig.tracked)]?.isVisible = true
        rig.policy.facts[ObjectIdentifier(rig.tracked)]?.systemVisible = true
        rig.center.post(name: NSApplication.didUnhideNotification, object: nil)
        try await rig.until("it comes back when the app unhides") { rig.changes.last == CheckerRig.Change(rig.tracked, false) }
    }

    /// An off-screen window that closes is dropped, never reported back on screen.
    @Test func aClosingOffScreenWindowIsDroppedNotShown() async throws {
        let rig = CheckerRig()
        defer { rig.stop() }
        rig.policy.facts[ObjectIdentifier(rig.tracked)]?.isMiniaturized = true
        rig.policy.facts[ObjectIdentifier(rig.tracked)]?.isVisible = false
        rig.policy.facts[ObjectIdentifier(rig.tracked)]?.systemVisible = false
        rig.checker.start()
        try await rig.until("the minimized window goes off screen") { rig.changes == [CheckerRig.Change(rig.tracked, true)] }
        rig.isTracking = false
        rig.post(NSWindow.willCloseNotification, rig.tracked)
        #expect(rig.closed == [ObjectIdentifier(rig.tracked)])
        try await rig.until("the close ran a pass") { rig.checker.passes == 2 }
        #expect(rig.changes == [CheckerRig.Change(rig.tracked, true)], "the closing window was reported on screen")
        #expect(!rig.checker.isOffScreen(rig.tracked))
    }

    // MARK: Pages

    /// The acceptance case: the tab beside the shown one in a minimized window is due after the
    /// timeout, never while the window is visible; the shown page stays as the active tab.
    @Test func aNeighborInAMinimizedWindowIsDueAfterTheTimeoutNeverWhileVisible() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (shown, neighbor) = try await rig.showPageWithNeighbor("minimized")
        try await Task.sleep(for: .seconds(2))
        #expect(rig.services.cache.phase(of: shown) == .mountedVisible, "a page on screen left its visible phase")
        #expect(!rig.isHibernated(neighbor), "a neighbor of a page on screen was discarded")
        #expect(rig.exemption(neighbor) == .neighbor)

        rig.minimize()
        try await rig.until("the neighbor is discarded after the timeout") { rig.isHibernated(neighbor) }
        try await rig.until("the shown page is kept as the active tab") { rig.exemption(shown) == .activeTab }
        #expect(rig.services.cache.phase(of: shown) == .mountedVisible, "the shown page was hidden with its window")
        #expect(!rig.isHibernated(shown))

        rig.restore()
        try await rig.until("the neighbor wakes when its window shows") { rig.services.cache.phase(of: neighbor) != .hibernated }
        try await rig.until("the shown page is no longer kept as off screen") { rig.exemption(shown) == nil }
    }

    @Test func aNeighborInAWindowCoveredByAnotherCmuxWindowIsDiscarded() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (shown, neighbor) = try await rig.showPageWithNeighbor("covered")
        rig.cover()
        try await rig.until("the covered window's neighbor is discarded") { rig.isHibernated(neighbor) }
        #expect(rig.services.cache.phase(of: shown) == .mountedVisible)
        #expect(rig.exemption(shown) == .activeTab)

        rig.uncover()
        try await rig.until("the neighbor wakes when its window is uncovered") {
            rig.services.cache.phase(of: neighbor) != .hibernated
        }
    }

    /// Displays asleep overnight: the page each window shows is not discarded, so waking the
    /// displays reloads nothing the person was looking at.
    @Test func displaySleepPastTheTimeoutKeepsTheShownPage() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let key = try await rig.showPage("asleep")
        rig.workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await rig.until("the shown page is kept as the active tab") { rig.exemption(key) == .activeTab }
        try await Task.sleep(for: .seconds(2))
        #expect(!rig.isHibernated(key), "display sleep discarded the page on screen")
        #expect(rig.services.cache.phase(of: key) == .mountedVisible)
        rig.workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await rig.until("the page is on screen again") { rig.exemption(key) == nil }
    }

    /// Closing a minimized window does not restore the pages it discarded while its panes go.
    @Test func closingAnOffScreenWindowWakesNoPageInIt() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let (_, neighbor) = try await rig.showPageWithNeighbor("closing")
        rig.minimize()
        try await rig.until("the neighbor is discarded") { rig.isHibernated(neighbor) }
        rig.post(NSWindow.willCloseNotification, rig.window)
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.services.cache.phase(of: neighbor) == .hibernated, "closing the window restored its page")
        rig.services.cache.removePresenter(rig.pane)
        rig.hibernation.paneDidGo(ObjectIdentifier(rig.pane))
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.services.cache.phase(of: neighbor) == .hibernated, "the closing window's teardown restored its page")
    }

    /// Without the feature (no checker) a minimized window's pages stay as they are.
    @Test func withoutTheCheckerAMinimizedWindowsPagesStay() async throws {
        let rig = try Rig(follows: false)
        defer { rig.close() }
        let (shown, neighbor) = try await rig.showPageWithNeighbor("unfollowed")
        rig.minimize()
        try await Task.sleep(for: .seconds(2))
        #expect(rig.services.cache.phase(of: shown) == .mountedVisible)
        #expect(!rig.isHibernated(neighbor))
    }

    /// The window manager's order report reaches the checker through hibernation.
    @Test func hibernationForwardsAReorderToItsChecker() async throws {
        let rig = try Rig()
        defer { rig.close() }
        try await rig.until("the first pass ran") { rig.checker.passes == 1 }
        rig.hibernation.windowsDidReorder()
        try await rig.until("the reorder ran a pass") { rig.checker.passes == 2 }
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

    static func makeWindow(_ frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// One tracked window and one window the checker does not track (an onboarding or debug window)
    /// in front of it, hidden at first; what the checker reported.
    @MainActor final class CheckerRig {
        struct Change: Equatable {
            var window: ObjectIdentifier
            var offScreen: Bool
            init(_ window: NSWindow, _ offScreen: Bool) {
                self.window = ObjectIdentifier(window)
                self.offScreen = offScreen
            }
        }

        let tracked: NSWindow
        let other: NSWindow
        let center = NotificationCenter()
        let policy: FakeDrawPolicy
        var appHidden = false
        /// False once the tracked window is gone from the app's list (its controller closed).
        var isTracking = true
        var order: @MainActor () -> [NSWindow] = { [] }
        private(set) var changes: [Change] = []
        private(set) var closed: [ObjectIdentifier] = []
        private(set) var checker: WindowOcclusionChecker!

        init() {
            tracked = OccludedWindowDiscardTests.makeWindow(NSRect(x: 100, y: 100, width: 400, height: 300))
            other = OccludedWindowDiscardTests.makeWindow(NSRect(x: 0, y: 0, width: 1000, height: 800))
            policy = FakeDrawPolicy()
            policy.facts[ObjectIdentifier(tracked)] = WindowOcclusionFacts(id: ObjectIdentifier(tracked), frame: tracked.frame)
            policy.facts[ObjectIdentifier(other)] = WindowOcclusionFacts(id: ObjectIdentifier(other), frame: other.frame,
                                                                        isVisible: false, systemVisible: false)
            order = { [tracked, other] in [other, tracked] }
            checker = WindowOcclusionChecker(
                windows: { [weak self] in self.map { $0.isTracking ? [$0.tracked] : [] } ?? [] },
                orderedWindows: { [weak self] in self?.order() ?? [] },
                facts: { [policy] in policy.read($0) }, isAppHidden: { [weak self] in self?.appHidden ?? false },
                drawsWhenOccluded: false, center: center, workspaceEvents: AppEvents(center: NotificationCenter()),
                mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            checker.onChange = { [weak self] window, offScreen in
                guard let self else { return }
                changes.append(Change(window == ObjectIdentifier(tracked) ? tracked : other, offScreen))
            }
            checker.onClose = { [weak self] window in self?.closed.append(window) }
        }

        func post(_ name: Notification.Name, _ target: NSWindow) { center.post(name: name, object: target) }

        func until(_ what: @autoclosure () -> String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(condition(), "\(what()) never happened")
        }

        func stop() {
            checker.stop()
            tracked.close()
            other.close()
        }
    }

    /// The app's cache and hibernation (a 0.6 s timeout, no freeze, one neighbor on each side), one
    /// pane in `window`, a second cmux window `coverWindow` that can cover it, and the checker with
    /// the fake draw policy's facts.
    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let window: NSWindow
        let coverWindow: NSWindow
        let center = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        /// The checker's displays' sleep and wake, on ``workspaceCenter``; kept here, as a subscription holds its fan-out weakly.
        let workspaceEvents: AppEvents
        let policy = FakeDrawPolicy()
        let checker: WindowOcclusionChecker
        let pane: Pane
        let folder: URL
        var keys: [String] = []
        var factReads: Int { policy.reads }

        init(follows: Bool = true) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
            services.cache.hibernation = hibernation
            hibernation.apply(BrowserHibernationSetting(mode: .minutes(0.01), freezeSeconds: nil, neighborRadius: 1))
            let window = OccludedWindowDiscardTests.makeWindow(NSRect(x: 100, y: 100, width: 400, height: 300))
            let coverWindow = OccludedWindowDiscardTests.makeWindow(NSRect(x: 0, y: 0, width: 1000, height: 800))
            self.window = window
            self.coverWindow = coverWindow
            pane = Pane(window: window)
            policy.facts[ObjectIdentifier(window)] = WindowOcclusionFacts(id: ObjectIdentifier(window), frame: window.frame, isActive: true)
            policy.facts[ObjectIdentifier(coverWindow)] = WindowOcclusionFacts(id: ObjectIdentifier(coverWindow), frame: coverWindow.frame,
                                                                              isVisible: false, systemVisible: false)
            workspaceEvents = AppEvents(center: workspaceCenter)
            checker = WindowOcclusionChecker(windows: { return [window, coverWindow] }, orderedWindows: { return [coverWindow, window] },
                                             facts: { [policy] in policy.read($0) }, isAppHidden: { false }, drawsWhenOccluded: false,
                                             center: center, workspaceEvents: workspaceEvents, mainWork: services.mainWork)
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

        /// Two tabs in the pane: `shown`, and `neighbor` beside it, hidden and kept awake as its neighbor.
        func showPageWithNeighbor(_ name: String) async throws -> (shown: String, neighbor: String) {
            let neighbor = try await showPage("\(name)-neighbor")
            let shown = try await showPage(name)
            hibernation.paneDidChange(ObjectIdentifier(pane), order: [shown, neighbor], selected: shown)
            services.cache.withdraw(neighbor, by: pane)
            try #require(services.cache.phase(of: neighbor) == .mountedHidden)
            return (shown, neighbor)
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
