import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// What the removal of the screen-change transition (#40234, `ScreenSwitchOneFrameTests`) left open. A change of
/// screen is complete in the turn that applies it, in every case: also for a screen whose view is made in the sync
/// that shows it (a reopened, duplicated or restored screen), and with no work for the screens that stay hidden.
/// Every test here is the clock: no display link ticks.
@MainActor
@Suite(.closesItsWindows)
struct ScreenSwitchFollowUpTests {
    /// Pane content that hears how its chrome changes (`PaneContentChrome.setChromeEmphasis`).
    final class Content: NSView, PaneContentChrome {
        var paneHeaderHeight: CGFloat { 0 }
        var onPaneHeaderHeightChange: (() -> Void)?
        var emphasisAnimated: [Bool] = []
        func setPaneContentCornerRadius(_ radius: CGFloat) {}
        func setChromeEmphasis(_ emphasis: ChromeEmphasis, animated: Bool) { emphasisAnimated.append(animated) }
    }

    final class Panes: LayoutPaneContentProvider {
        var contents: [PaneID: Content] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let content = Content()
            contents[pane] = content
            return content
        }
    }

    final class Count {
        var value = 0
    }

    static func pair(_ prefix: String) -> ScreenLayout {
        .splits(.split(SplitID("\(prefix)1"), axis: .horizontal, ratio: 0.5, a: .leaf(PaneID("\(prefix)-p1")), b: .leaf(PaneID("\(prefix)-p2"))))
    }

    /// A strip wider than the window: 4 columns of 45 %.
    static func columns(_ prefix: String) -> ScreenLayout {
        .columns((1...4).map {
            LayoutColumn(id: ColumnID("\(prefix)-c\($0)"), width: 0.45, root: .leaf(PaneID("\(prefix)-p\($0)")))
        })
    }

    static func screen(_ id: String, _ layout: ScreenLayout) -> LayoutScreen {
        LayoutScreen(id: ScreenID(id), name: id, layout: layout)
    }

    /// The center mode pinned to `.never`, whatever the process-wide design settings another test left.
    static let never: (LayoutModel) -> Void = { $0.centerFocusedColumnOverride = .never }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// The screens in a window, the first one shown (or `active`), pane animations on. Every screen is laid out at the
    /// root's size, the hidden ones too, as in the app (a workspace's root has its size before its screens are made).
    final class Layout {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ screens: [LayoutScreen], active: ScreenID? = nil, focused: PaneID, width: CGFloat = 1200, overlayHost: Bool = false,
             configure: (LayoutModel) -> Void = { _ in }) {
            model = LayoutModel(screens: screens, activeScreenID: active ?? screens[0].id, focusedPane: focused)
            model.splitSizingOverride = .even
            configure(model)
            root = LayoutRootView(model: model, contentProvider: provider)
            // Motion allowed and pane layout animated (`LayoutContext.animatesPaneLayout`), whatever the host's settings.
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            if overlayHost { _ = WindowOverlayHost.host(for: window) }
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The root was made with no size, so its hidden screens wait for their first show to lay out at the
            // window's size (`needsReconcileOnShow`). In the app they are made at the root's size: the same here, or
            // each first show in a test would be a show after a resize (`aScreenResizedWhileHidden...` is that case).
            root.screenViews.values.forEach { $0.reconcileIfDeferred() }
            root.driver.isManual = true
        }

        /// Resizes the window, as a person does while another screen shows.
        func resize(width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 800))
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }

        func view(_ screen: ScreenID) throws -> ScreenContentView { try #require(root.screenViews[screen]) }

        func select(_ screen: ScreenID) {
            model.selectScreen(screen)
            root.syncWithModel()
        }

        /// Closes the window and the overlay panel its `WindowOverlayHost` keeps.
        func tearDown() {
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            window.closeAfterTest()
            panel?.close()
        }
    }

    // MARK: A screen made in the sync that shows it

    /// A reopened, duplicated or restored screen comes with the change that shows it. Its view is made in that sync,
    /// shown: a center request in the same change put its camera on a spring after the screen showed.
    @Test func aScreenMadeInTheSyncThatShowsItCentersItsColumnAtRest() throws {
        let a = Self.screen("a", Self.pair("a")), b = Self.screen("b", .splits(.leaf("b-p1")))
        let layout = Layout([a, b], focused: "a-p1")
        defer { layout.tearDown() }
        try #require(layout.root.context.animatesPaneLayout, "pane animations are off: the camera would not have sprung")
        let asked = layout.root.driver.startRequests

        layout.model.apply(screens: [a, b, Self.screen("c", Self.columns("c"))])
        try #require(layout.model.centerColumn(containing: "c-p3"))
        try #require(layout.model.activeScreenID == "c", "the center request did not show the new screen")
        layout.root.syncWithModel()

        let strip = try layout.view("c")
        #expect(!strip.isHidden && strip.frame == layout.root.bounds && strip.alphaValue == 1, "the new screen shows")
        #expect(strip.scroll.target > 1, "the camera did not go to the centered column (\(strip.scroll.target))")
        #expect(strip.scroll.value == strip.scroll.target,
                "the camera is on a spring after the screen shows (\(strip.scroll.value) -> \(strip.scroll.target))")
        #expect(!strip.hasMotion)
        #expect(layout.root.driver.startRequests == asked, "the change asked for display frames")
        #expect(!layout.root.isInLayoutMotion, "the change put the layout in motion")
    }

    /// The same for a reveal request (a tab opened in a column out of view of a screen that comes with it).
    @Test func aScreenMadeInTheSyncThatShowsItRevealsItsColumnAtRest() throws {
        let a = Self.screen("a", Self.pair("a")), b = Self.screen("b", .splits(.leaf("b-p1")))
        let layout = Layout([a, b], focused: "a-p1")
        defer { layout.tearDown() }
        try #require(layout.root.context.animatesPaneLayout, "pane animations are off: the camera would not have sprung")
        let asked = layout.root.driver.startRequests

        layout.model.apply(screens: [a, b, Self.screen("c", Self.columns("c"))])
        layout.model.selectScreen("c")
        try #require(layout.model.focusedPane == "c-p1")
        layout.model.revealColumn(containing: "c-p4")
        layout.root.syncWithModel()

        let strip = try layout.view("c")
        #expect(!strip.isHidden && strip.frame == layout.root.bounds && strip.alphaValue == 1, "the new screen shows")
        #expect(strip.scroll.target > 1, "the camera did not go to the revealed column (\(strip.scroll.target))")
        #expect(strip.scroll.value == strip.scroll.target,
                "the camera is on a spring after the screen shows (\(strip.scroll.value) -> \(strip.scroll.target))")
        #expect(!strip.hasMotion)
        #expect(layout.root.driver.startRequests == asked, "the change asked for display frames")
    }

    // MARK: A hidden screen the switch shows (pins of #40234's gate)

    /// A center request that shows a hidden screen (focus lands on its column) lands in the same turn.
    @Test func aCenterRequestThatShowsAHiddenScreenLandsAtRest() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", Self.columns("b"))], focused: "a-p1", configure: Self.never)
        defer { layout.tearDown() }
        let strip = try layout.view("b")
        try #require(strip.isHidden && layout.root.context.animatesPaneLayout)
        let asked = layout.root.driver.startRequests

        try #require(layout.model.centerColumn(containing: "b-p3"))
        layout.root.syncWithModel()
        #expect(!strip.isHidden, "the request did not show the screen of its pane")
        #expect(strip.scroll.target > 1 && strip.scroll.value == strip.scroll.target,
                "the camera is on a spring after the screen shows (\(strip.scroll.value) -> \(strip.scroll.target))")
        #expect(!strip.hasMotion)
        #expect(layout.root.driver.startRequests == asked, "the change asked for display frames")

        // Where the same request puts the camera of a screen that shows already.
        let shown = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", Self.columns("b"))], active: "b", focused: "b-p1", configure: Self.never)
        defer { shown.tearDown() }
        try #require(shown.model.centerColumn(containing: "b-p3"))
        shown.root.syncWithModel()
        let other = try shown.view("b")
        let centered = other.scroll.target
        try #require(centered > 1 && centered < other.geometry.maxOffset - 1,
                     "the centered column is at an end of the strip: the test could not tell a center from a reveal")
        #expect(abs(strip.scroll.target - centered) < 1, "the camera is at \(strip.scroll.target), the centered column is at \(centered)")
    }

    /// A reveal request with the switch that shows its screen lands in the same turn.
    @Test func aRevealRequestWithTheSwitchThatShowsItsScreenLandsAtRest() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", Self.columns("b"))], focused: "a-p1", configure: Self.never)
        defer { layout.tearDown() }
        let strip = try layout.view("b")
        try #require(strip.isHidden && layout.root.context.animatesPaneLayout)
        let asked = layout.root.driver.startRequests

        layout.model.selectScreen("b")
        layout.model.revealColumn(containing: "b-p4")
        layout.root.syncWithModel()
        #expect(!strip.isHidden)
        #expect(strip.scroll.target > 1 && strip.scroll.value == strip.scroll.target,
                "the camera is on a spring after the screen shows (\(strip.scroll.value) -> \(strip.scroll.target))")
        #expect(!strip.hasMotion)
        #expect(layout.root.driver.startRequests == asked, "the change asked for display frames")

        // Where the same request puts the camera of a screen that shows already.
        let shown = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", Self.columns("b"))], active: "b", focused: "b-p1", configure: Self.never)
        defer { shown.tearDown() }
        shown.model.revealColumn(containing: "b-p4")
        shown.root.syncWithModel()
        let revealed = try shown.view("b").scroll.target
        try #require(revealed > 1)
        #expect(abs(strip.scroll.target - revealed) < 1, "the camera is at \(strip.scroll.target), the revealed column is at \(revealed)")
    }

    /// A screen resized while hidden lays out at its new size before a request that comes with its switch: the
    /// request ran on the old size, and the layout the show ran after it put the camera somewhere else.
    @Test func aScreenResizedWhileHiddenCentersItsColumnAtTheSizeItShowsWith() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", Self.columns("b"))], focused: "a-p1", configure: Self.never)
        defer { layout.tearDown() }
        let strip = try layout.view("b")
        layout.resize(width: 1000)
        try #require(strip.isHidden && layout.root.bounds.width == 1000 && strip.frame.width == 1000)
        let asked = layout.root.driver.startRequests

        try #require(layout.model.centerColumn(containing: "b-p3"))
        layout.root.syncWithModel()
        try #require(!strip.isHidden)
        #expect(strip.scroll.value == strip.scroll.target && !strip.hasMotion, "the screen is not at rest")
        #expect(layout.root.driver.startRequests == asked, "the change asked for display frames")

        // The same request on a screen made at that size.
        let made = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", Self.columns("b"))], focused: "a-p1", width: 1000, configure: Self.never)
        defer { made.tearDown() }
        try #require(made.model.centerColumn(containing: "b-p3"))
        made.root.syncWithModel()
        let other = try made.view("b")
        let centered = other.scroll.target
        try #require(centered > 1 && centered < other.geometry.maxOffset - 1)
        #expect(abs(strip.scroll.target - centered) < 1,
                "the camera is at \(strip.scroll.target); the column centered at the size the screen shows with is at \(centered)")
    }

    /// A screen that hides while its camera springs lands the camera in that turn: it gets no frames while hidden, and
    /// the camera went on from the middle of its way after the screen showed again.
    @Test func aScreenThatHidesMidCameraSpringLandsItAndShowsAgainAtRest() throws {
        let layout = Layout([Self.screen("a", Self.columns("a")), Self.screen("b", .splits(.leaf("b-p1")))], focused: "a-p1", configure: Self.never)
        defer { layout.tearDown() }
        let strip = try layout.view("a")
        try #require(layout.root.context.animatesPaneLayout)
        layout.model.focus("a-p4")
        layout.root.syncWithModel()
        _ = layout.root.advanceFrame(1.0 / 120)
        try #require(strip.scroll.value != strip.scroll.target, "the focus move did not put the camera on a spring")
        let target = strip.scroll.target

        layout.select("b")
        try #require(strip.isHidden)
        #expect(strip.scroll.value == target && strip.scroll.target == target,
                "the screen that hid keeps its camera mid-spring (\(strip.scroll.value) -> \(strip.scroll.target), was going to \(target))")
        #expect(!strip.hasMotion)
        // The frame tick the camera spring had asked for finds nothing to move, and the layout is at rest after it.
        #expect(!layout.root.advanceFrame(1.0 / 120), "a frame after the switch still moves something")
        #expect(!layout.root.isInLayoutMotion)

        let asked = layout.root.driver.startRequests
        layout.select("a")
        try #require(!strip.isHidden)
        #expect(strip.scroll.value == strip.scroll.target && !strip.hasMotion,
                "the camera moves after the screen shows again (\(strip.scroll.value) -> \(strip.scroll.target))")
        #expect(layout.root.driver.startRequests == asked, "the switch back asked for display frames")
        #expect(!layout.root.isInLayoutMotion)
    }

    /// The chrome of the screen a switch shows is at rest when it shows: its panes hear their new emphasis with no
    /// animation. A focus move on the shown screen still animates it (so the probe is not blind).
    @Test func theScreenASwitchShowsHasItsChromeAtRest() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", Self.pair("b"))], focused: "a-p1")
        defer { layout.tearDown() }
        let first = try #require(layout.provider.contents["b-p1"]), second = try #require(layout.provider.contents["b-p2"])
        (first.emphasisAnimated, second.emphasisAnimated) = ([], [])

        layout.select("b")
        try #require(layout.model.focusedPane == "b-p1")
        try #require(!first.emphasisAnimated.isEmpty, "the pane that took focus did not hear its chrome change")
        #expect(!(first.emphasisAnimated + second.emphasisAnimated).contains(true),
                "the chrome of the screen that shows fades after it shows: \(first.emphasisAnimated) \(second.emphasisAnimated)")

        (first.emphasisAnimated, second.emphasisAnimated) = ([], [])
        layout.model.focus("b-p2")
        layout.root.syncWithModel()
        #expect(first.emphasisAnimated == [true] && second.emphasisAnimated == [true],
                "a focus move on the shown screen animates the chrome of its two panes: \(first.emphasisAnimated) \(second.emphasisAnimated)")
    }

    // MARK: The screens that stay hidden

    /// Work per switch is O(the 2 screens that change): a screen that stays hidden gets no scroll sync and no
    /// presentation pass, and none for a focus move on the shown screen. Before, each switch and each focus move
    /// ran one for every mounted screen.
    @Test func aScreenThatStaysHiddenIsNotTouchedByASwitchOrAFocusMove() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", .splits(.leaf("b-p1"))),
                             Self.screen("c", Self.columns("c"))], focused: "a-p1")
        defer { layout.tearDown() }
        let second = try layout.view("b"), third = try layout.view("c")
        try #require(second.isHidden && third.isHidden)

        var passes = third.presentationPasses
        layout.select("b")
        #expect(third.presentationPasses == passes,
                "a switch between two other screens ran \(third.presentationPasses - passes) presentation pass(es) of a hidden screen")

        layout.select("a")
        passes = second.presentationPasses + third.presentationPasses
        layout.model.focus("a-p2")
        layout.root.syncWithModel()
        try #require(layout.model.focusedPane == "a-p2" && layout.model.activeScreenID == "a")
        #expect(second.presentationPasses + third.presentationPasses == passes,
                "a focus move on the shown screen ran \(second.presentationPasses + third.presentationPasses - passes) presentation pass(es) of hidden screens")
    }

    /// What a screen missed while it stayed hidden (other switches, a new center mode) it has when it shows, at rest.
    @Test func aScreenThatStayedHiddenShowsWithItsCameraOnItsFocusedColumn() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", .splits(.leaf("b-p1"))),
                             Self.screen("c", Self.columns("c"))], focused: "a-p1", configure: Self.never)
        defer { layout.tearDown() }
        let strip = try layout.view("c")
        layout.select("b")
        layout.select("a")
        layout.model.centerFocusedColumnOverride = .always
        layout.root.syncWithModel()
        try #require(strip.isHidden)
        let asked = layout.root.driver.startRequests

        layout.model.focus("c-p3")
        layout.root.syncWithModel()
        try #require(layout.model.activeScreenID == "c")
        #expect(!strip.isHidden && strip.frame == layout.root.bounds)
        #expect(strip.scrollState.mode == .always, "the screen did not get the center mode set while it was hidden")
        #expect(strip.scroll.value == strip.scroll.target, "the camera is on a spring after the screen shows")
        #expect(!strip.hasMotion)
        #expect(layout.root.driver.startRequests == asked, "the switch asked for display frames")

        // Centered, not only in view: where the same focus move puts the camera of a screen that shows, in that mode.
        let shown = Layout([Self.screen("a", Self.pair("a")), Self.screen("c", Self.columns("c"))], active: "c", focused: "c-p1") {
            $0.centerFocusedColumnOverride = .always
        }
        defer { shown.tearDown() }
        shown.model.focus("c-p3")
        shown.root.syncWithModel()
        let other = try shown.view("c")
        let centered = other.scroll.target
        try #require(centered > 1 && centered < other.geometry.maxOffset - 1)
        #expect(abs(strip.scroll.target - centered) < 1, "the camera is at \(strip.scroll.target), the centered column is at \(centered)")
    }

    // MARK: What follows the panes

    /// What follows the panes once per placed frame (shortcut hint chips, `onFramePlaced`) hears a switch in its
    /// turn: no frame runs after it now, so nothing else tells it that the panes under it changed.
    @Test func aScreenSwitchTellsWhatFollowsThePanesInItsTurn() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", .splits(.leaf("b-p1")))], focused: "a-p1")
        defer { layout.tearDown() }
        let placed = Count()
        layout.root.onFramePlaced = { placed.value += 1 }

        layout.select("b")
        #expect(placed.value == 1, "the switch told what follows the panes \(placed.value) time(s)")
    }

    /// The same for a switch that comes in a key's held turn (a close that removes the shown screen,
    /// `syncWithModelForNextFrame`): when every screen snapped, no frame tick follows the hold.
    @Test func aScreenSwitchInAHeldTurnTellsWhatFollowsThePanes() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", .splits(.leaf("b-p1")))], focused: "a-p1")
        defer { layout.tearDown() }
        try #require(layout.root.isLive && layout.root.driver.isAttached, "the root runs no frames: the hold is not taken")
        let placed = Count()
        layout.root.onFramePlaced = { placed.value += 1 }

        let next = try layout.view("b")
        layout.model.selectScreen("b")
        layout.root.syncWithModelForNextFrame()
        try #require(!next.isHidden && !layout.root.driver.isRunning, "a frame tick follows: it tells them")
        #expect(placed.value == 1, "the switch told what follows the panes \(placed.value) time(s)")
    }

    /// The focus rings and dims (the overlay plane) follow the switch in its turn: the shown screen's are placed over
    /// its panes, the hidden screen's are gone.
    @Test func aScreenSwitchMovesTheRingsToTheShownScreenInItsTurn() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", Self.pair("b"))], focused: "a-p1")
        defer { layout.tearDown() }
        let plane = layout.root.overlayPlane
        let old = try (["a-p1", "a-p2"] as [PaneID]).map { try #require(layout.root.context.hosts[$0]) }
        let new = try (["b-p1", "b-p2"] as [PaneID]).map { try #require(layout.root.context.hosts[$0]) }
        try #require(old.allSatisfy { $0.chrome.superview === plane } && new.allSatisfy { $0.chrome.superview !== plane },
                     "the rings of screen a are not the ones shown")

        layout.select("b")
        for host in new {
            #expect(host.chrome.superview === plane, "\(host.pane.rawValue): no ring over a pane of the shown screen")
            #expect(host.chrome.frame == layout.root.convert(host.bounds, from: host), "\(host.pane.rawValue): its ring is not over it")
        }
        #expect(old.allSatisfy { $0.chrome.superview !== plane }, "a ring of the hidden screen stays over the shown one")
    }

    /// Divider hover follows the switch under a still pointer: the screen that hides gives its hover back, the one
    /// that shows takes it, each with one hover refresh. Before, the screen that hid refreshed twice.
    @Test func aScreenSwitchRefreshesDividerHoverOncePerScreenThatChanges() throws {
        let layout = Layout([Self.screen("a", Self.pair("a")), Self.screen("b", .splits(.leaf("b-p1")))], focused: "a-p1") {
            // A pinned style, whatever the process-wide design settings another test left.
            $0.followsDesignMetrics = false
        }
        defer { layout.tearDown() }
        let screen = try layout.view("a")
        let handle = try #require(screen.dividerViews[.split("a1")])
        let spot = screen.convert(handle.cursorRectInBounds, from: handle)
        try #require(spot.width > 0 && spot.height > 0, "the divider has no cursor rect: \(spot)")
        let pointer = screen.convert(CGPoint(x: spot.midX, y: spot.midY), to: nil)
        let reads = Count()
        layout.root.context.hoverPointer = { _ in
            reads.value += 1
            return pointer
        }
        layout.root.context.hoverReachesWindow = { _ in true }
        screen.refreshDividerHover()
        try #require(handle.isHovered, "the pointer on the divider does not hover it")

        reads.value = 0
        layout.select("b")
        #expect(!handle.isHovered, "a divider of the hidden screen stays hovered")
        #expect(reads.value == 2, "the switch refreshed divider hover \(reads.value) times for the 2 screens that changed")

        reads.value = 0
        layout.select("a")
        #expect(handle.isHovered, "the screen that shows under a still pointer does not hover its divider in the switch's turn")
        #expect(reads.value == 2, "the switch back refreshed divider hover \(reads.value) times for the 2 screens that changed")
    }

    /// The scrollbar thumb is a hole in the pages above it (an occluder of the window): the switch moves the hole from
    /// the old screen's thumb to the new screen's, in its turn.
    @Test func aScreenSwitchMovesTheScrollbarOccluderToTheShownScreen() throws {
        let layout = Layout([Self.screen("a", Self.columns("a")), Self.screen("b", Self.columns("b"))], focused: "a-p4",
                            overlayHost: true) { $0.stripScrollbarOverride = .always }
        defer { layout.tearDown() }
        let host = try #require(WindowOverlayHost.existingHost(for: layout.window))
        let old = try #require(try layout.view("a").scrollbar), new = try #require(try layout.view("b").scrollbar)
        func thumb(_ bar: StripScrollbarView) throws -> CGRect { try #require(bar.thumbRect.map { bar.convert($0, to: nil) }) }
        try #require(try !Self.same(thumb(old), thumb(new)), "the two thumbs are at the same place: the test could not tell them apart")
        try #require(try host.occluderRects.count == 1 && Self.same(host.occluderRects[0], thumb(old)),
                     "the shown screen's thumb is not the window's one occluder: \(host.occluderRects)")

        layout.select("b")
        #expect(host.occluderRects.count == 1, "one thumb shows, so one occluder: \(host.occluderRects)")
        #expect(try host.occluderRects.contains { try Self.same($0, thumb(new)) }, "no hole at the shown screen's thumb: \(host.occluderRects)")

        layout.select("a")
        #expect(host.occluderRects.count == 1, "one thumb shows, so one occluder: \(host.occluderRects)")
        #expect(try host.occluderRects.contains { try Self.same($0, thumb(old)) }, "no hole at the thumb of the screen shown again: \(host.occluderRects)")
    }

    // MARK: The active screen goes away

    /// The shown screen is removed (its workspace closed): the next one shows at rest in the same turn.
    @Test func removingTheShownScreenShowsTheNextOneAtRestInThatTurn() throws {
        let a = Self.screen("a", Self.pair("a")), b = Self.screen("b", Self.columns("b"))
        let layout = Layout([a, b], focused: "a-p1")
        defer { layout.tearDown() }
        let next = try layout.view("b")
        try #require(next.isHidden)
        let asked = layout.root.driver.startRequests

        layout.model.apply(screens: [b])
        try #require(layout.model.activeScreenID == "b")
        layout.root.syncWithModel()
        #expect(layout.root.screenViews["a"] == nil, "the removed screen keeps its view")
        #expect(!next.isHidden && next.frame == layout.root.bounds && next.alphaValue == 1, "the next screen shows")
        #expect(next.scroll.value == next.scroll.target && !next.hasMotion, "the next screen is not at rest")
        #expect(layout.root.driver.startRequests == asked, "the change asked for display frames")
        #expect(!layout.root.isInLayoutMotion)
    }

    /// No active screen: every screen is hidden in that turn, at rest; and the last screen can go.
    @Test func noActiveScreenHidesEveryScreenAtRest() throws {
        let a = Self.screen("a", Self.pair("a")), b = Self.screen("b", .splits(.leaf("b-p1")))
        let layout = Layout([a, b], focused: "a-p1")
        defer { layout.tearDown() }
        let shown = try layout.view("a")
        // A split on the shown screen, mid-spring.
        layout.model.apply(screens: [Self.screen("a", .splits(.split("a1", axis: .horizontal, ratio: 0.5, a: .leaf("a-p1"),
                                                                     b: .split("a2", axis: .horizontal, ratio: 0.5, a: .leaf("a-p2"), b: .leaf("a-p3"))))), b])
        layout.root.syncWithModel()
        _ = layout.root.advanceFrame(1.0 / 120)
        try #require(shown.hasMotion, "the split on the shown screen did not spring")

        layout.root.showScreen(nil)
        let allHidden = layout.root.screenViews.values.allSatisfy { $0.isHidden }
        #expect(allHidden, "a screen stays shown with no active screen")
        #expect(!shown.hasMotion, "a screen that hid mid-spring stays frozen mid-motion")

        let asked = layout.root.driver.startRequests
        layout.model.apply(screens: [])
        try #require(layout.model.activeScreenID == nil)
        layout.root.syncWithModel()
        #expect(layout.root.screenViews.isEmpty, "a removed screen keeps its view")
        #expect(layout.root.driver.startRequests == asked, "the change asked for display frames")
    }
}
