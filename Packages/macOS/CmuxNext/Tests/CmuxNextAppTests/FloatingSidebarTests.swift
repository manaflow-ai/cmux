import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Testing

/// The floating sidebar (`sidebar.floatOnHover`, Lawrence 2026-11-08: "if sidebar is closed, we
/// should have a toggleable mode, that will show a floating version of sidebar if mouse moves to
/// left (make it intuitive) this behavior needs to be toggleable"). With the sidebar hidden, the
/// pointer resting on the window's sidebar edge floats it over the content (no relayout); leaving
/// it closes it after a grace delay unless a menu, drag or edit holds it; Toggle Sidebar shows it
/// where it is; the setting turns it off; Home never floats it.
@Suite(.closesItsWindows, .serialized)
@MainActor struct FloatingSidebarTests {
    // MARK: Model

    @Test func aFloatingHiddenSidebarTakesItsWidthButNotTheContentsPlace() {
        let model = SidebarModel()
        model.width = 260
        model.presentation = .hidden
        #expect(model.displayWidth == 0)
        model.isFloating = true
        #expect(model.displayWidth == 260, "the float is the sidebar at the user's width")
        #expect(model.contentInset == 0, "the content keeps the window edge under the float")
        #expect(model.isHidden, "a float is a hidden sidebar: the toggle and saved state still say hidden")
    }

    @Test func toggleSidebarWhileFloatingShowsItWhereItIs() {
        let model = SidebarModel()
        model.width = 260
        model.presentation = .hidden
        model.isFloating = true
        model.toggle()
        #expect(model.presentation == .shown)
        #expect(!model.isFloating, "shown, the sidebar has its place beside the content")
        #expect(model.displayWidth == 260)
        #expect(model.contentInset == 260)
    }

    @Test func showingTheSidebarFromAnyPathEndsTheFloat() {
        let model = SidebarModel()
        model.presentation = .hidden
        model.isFloating = true
        model.presentation = .shown
        #expect(!model.isFloating)
    }

    @Test func theSettingIsOnByDefault() {
        #expect(SidebarSectionsPreferences.defaults.floatOnHover)
    }

    // MARK: Window

    /// A window root in a titled, full-size-content window, sidebar hidden at 260 pt, motion reduced so slides land
    /// in the turn that starts them.
    private func hiddenRoot(clock: ManualClock = ManualClock()) -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.width = 260
        model.presentation = .hidden
        let root = WindowRootView(sidebar: SidebarContainerView(model: model), revealClock: clock)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.sidebar.restore(width: 260, presentation: .hidden)
        root.sidebarHidden = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    private func withReducedMotion<T>(_ body: () throws -> T) rethrows -> T {
        let previous = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previous }
        return try body()
    }

    @Test func floatingCoversTheContentWithoutMovingIt() {
        withReducedMotion {
            let (window, root) = hiddenRoot()
            defer { window.close() }
            let content = root.contentHost.frame
            root.sidebar.model.isFloating = true
            root.sidebar.apply()
            root.layoutSubtreeIfNeeded()
            #expect(root.sidebar.isFloatOverlay)
            #expect(root.contentHost.frame == content, "no relayout: the content stays at the window edge under the card")
            #expect(root.sidebar.frame.width == 260 + SidebarContainerView.floatInset)
            #expect(root.sidebar.paneReach == 0, "a card of its own reaches into no gutter")
            #expect(root.sidebar.handle.isHidden, "the float has no resize edge")
            let index = { (view: NSView) in root.subviews.firstIndex { $0 === view } ?? -1 }
            #expect(index(root.sidebar) > index(root.contentHost), "the card draws above the content")
        }
    }

    @Test func theCardIsInsetAndConcentricWithTheWindow() {
        withReducedMotion {
            let (window, root) = hiddenRoot()
            defer { window.close() }
            root.sidebar.model.isFloating = true
            root.sidebar.apply()
            root.layoutSubtreeIfNeeded()
            let inset = SidebarContainerView.floatInset
            let card = root.sidebar.panel.convert(root.sidebar.panel.bounds, to: root)
            #expect(abs(card.minX - inset) < 0.5, "inset from the window's sidebar edge")
            #expect(abs(card.minY - inset) < 0.5 && abs(root.bounds.maxY - card.maxY - inset) < 0.5, "and from its top and bottom")
            #expect(root.sidebar.panel.layer?.cornerRadius == root.mainPaneCornerRadius, "the main pane's concentric radius")
            #expect(root.sidebar.panel.layer?.masksToBounds == true)
        }
    }

    @Test func theFloatEndingLandsBackAtTheHiddenLayout() {
        withReducedMotion {
            let (window, root) = hiddenRoot()
            defer { window.close() }
            let content = root.contentHost.frame
            root.sidebar.model.isFloating = true
            root.sidebar.apply()
            root.layoutSubtreeIfNeeded()
            root.sidebar.model.isFloating = false
            root.sidebar.apply()
            root.layoutSubtreeIfNeeded()
            #expect(!root.sidebar.isFloatOverlay)
            #expect(root.sidebar.frame.width == 0)
            #expect(root.contentHost.frame == content)
        }
    }

    @Test func pinningAFloatGivesTheSidebarItsPlace() {
        withReducedMotion {
            let (window, root) = hiddenRoot()
            defer { window.close() }
            root.sidebar.model.isFloating = true
            root.sidebar.apply()
            root.layoutSubtreeIfNeeded()
            root.sidebar.model.toggle()
            root.sidebar.apply()
            root.layoutSubtreeIfNeeded()
            #expect(!root.sidebar.isFloatOverlay)
            #expect(root.sidebar.frame.width == 260)
            #expect(root.contentHost.frame.minX >= 260, "the content sits beside the shown sidebar")
        }
    }

    @Test func theEdgeZoneSitsOnTheWindowEdgeBelowTheTopRowOnlyWhileHidden() {
        let (window, root) = hiddenRoot()
        defer { window.close() }
        let zone = root.sidebarFloat.edgeZone.frame
        #expect(zone.minX == 0 && zone.width == FloatingSidebarReveal.edgeWidth)
        #expect(zone.maxY <= root.titlebarRevealRegion.frame.minY + 0.5, "the top row's corner opens the toolbar band instead")
        #expect(zone.height > root.bounds.height / 2)
        root.sidebarHidden = false
        root.sidebar.model.presentation = .shown
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        #expect(root.sidebarFloat.edgeZone.frame == .zero, "a shown sidebar has nothing to float")
    }

    @Test func homeNeverFloatsTheSidebar() {
        let (window, root) = hiddenRoot()
        defer { window.close() }
        root.sidebarFloat.isAllowed = { false }
        #expect(!root.sidebarFloat.reveal.canFloat)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        #expect(root.sidebarFloat.edgeZone.frame == .zero)
    }

    // MARK: Reveal timing

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "\(what)")
    }

    @Test func restingOnTheEdgeFloatsItAndPassingByDoesNot() async throws {
        let clock = ManualClock()
        let model = SidebarModel()
        model.presentation = .hidden
        let reveal = FloatingSidebarReveal(model: model, clock: clock)
        // A pass: in and out before the intent delay.
        reveal.setEdgeEngaged(true)
        try await clock.waitForSleeper()
        reveal.setEdgeEngaged(false)
        clock.advance(by: FloatingSidebarReveal.openDelay)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!model.isFloating, "a pointer passing the edge opens nothing")
        // A rest.
        reveal.setEdgeEngaged(true)
        try await clock.waitForSleeper()
        clock.advance(by: FloatingSidebarReveal.openDelay)
        try await until("resting on the edge floats the sidebar") { model.isFloating }
    }

    @Test func leavingClosesAfterTheGraceDelayAndReturningKeepsIt() async throws {
        let clock = ManualClock()
        let model = SidebarModel()
        model.presentation = .hidden
        let reveal = FloatingSidebarReveal(model: model, clock: clock)
        model.isFloating = true
        reveal.setPanelEngaged(true)
        reveal.setPanelEngaged(false)
        try await clock.waitForSleeper()
        reveal.setPanelEngaged(true) // back before the delay ran out
        clock.advance(by: FloatingSidebarReveal.closeDelay)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.isFloating, "a short overshoot does not drop it")
        reveal.setPanelEngaged(false)
        try await clock.waitForSleeper()
        clock.advance(by: FloatingSidebarReveal.closeDelay)
        try await until("leaving closes it after the delay") { !model.isFloating }
    }

    @Test func aMenuDragOrEditHoldsItOpenUntilItEnds() async throws {
        let clock = ManualClock()
        let model = SidebarModel()
        model.presentation = .hidden
        let reveal = FloatingSidebarReveal(model: model, clock: clock)
        var held = true
        reveal.holdsOpen = { held }
        model.isFloating = true
        reveal.setPanelEngaged(true)
        reveal.setPanelEngaged(false)
        try await clock.waitForSleeper()
        clock.advance(by: FloatingSidebarReveal.closeDelay)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.isFloating, "held open past the delay")
        held = false
        reveal.reconcile()
        try await clock.waitForSleeper()
        clock.advance(by: FloatingSidebarReveal.closeDelay)
        try await until("the hold's end lets it close") { !model.isFloating }
    }

    @Test func theSettingOffOrHomeNeverFloatsAndClosesAnOpenFloat() async throws {
        let clock = ManualClock()
        let model = SidebarModel()
        model.presentation = .hidden
        let reveal = FloatingSidebarReveal(model: model, clock: clock)
        var enabled = false
        reveal.isEnabled = { enabled }
        reveal.setEdgeEngaged(true)
        #expect(!reveal.canFloat)
        enabled = true
        var allowed = false
        reveal.isAllowed = { allowed }
        reveal.reconcile()
        #expect(!reveal.canFloat, "Home shows: no float")
        allowed = true
        model.isFloating = true
        enabled = false
        reveal.reconcile()
        #expect(!model.isFloating, "turning the setting off closes a float at once")
    }

    @Test func aShownSidebarNeverFloats() {
        let model = SidebarModel()
        let reveal = FloatingSidebarReveal(model: model, clock: ManualClock())
        #expect(!reveal.canFloat)
    }
}
