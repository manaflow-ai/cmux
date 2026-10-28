import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextWakeups
import QuartzCore
import Testing

/// The sidebar's show and hide on the render server (`motion.renderServer`
/// on). The toggle's turn sets the width constant once and lays the window out once at rest, so the
/// content takes its final size once, in that turn, while nothing is in pane motion (a terminal sends its
/// final grid now, one grid per toggle); then additive `RenderSpring`s carry the clip, the panel, the
/// handle, the card and the shade from where they showed, and nothing lays out again until the landing,
/// which runs once. With the gate off the slide lands in the toggle's turn. With the switch off the slide
/// stays on the main thread as before.
///
/// The spring checks read the layers' animations, so the window is real and ordered in, and a host where
/// nothing animates (no screen, a sleeping display, movement off) fails them (`requireAnimates`).
@MainActor @Suite(.serialized)
struct SidebarSlideMotionTests {
    /// The workspace content: each frame size it takes, whether it was in pane motion then (a terminal
    /// holds its grid while it is), and each layout pass that reached it.
    final class ContentProbe: NSView {
        var sizes: [CGSize] = []
        var inMotion: [Bool] = []
        var layouts = 0

        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            guard changed else { return }
            sizes.append(newSize)
            inMotion.append(isInPaneMotion)
            needsLayout = true // invalidate: a new size, laid out in the pass that set it (counted in `layouts`).
        }

        override func layout() {
            super.layout()
            layouts += 1
        }

        func reset() {
            sizes = []
            inMotion = []
            layouts = 0
        }
    }

    final class Fixture {
        let root: WindowRootView
        let content = ContentProbe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        /// Each time the width motion ended (`onWidthMotionChange(false)`).
        private(set) var landings = 0
        private var landing: CheckedContinuation<Bool, Never>?

        init(renderServer: Bool) {
            _ = NSApplication.shared
            root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel(), mainWork: MainWorkScheduler(budget: MainFrameBudget())),
                                  slideHoldsContent: { true }, rendersMotionOnServer: { renderServer })
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentView = root
            window.orderFrontRegardless()
            root.show(content)
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            content.frame = root.contentHost.bounds
            let windowLanding = root.sidebar.onWidthMotionChange
            root.sidebar.onWidthMotionChange = { [weak self] animating in
                windowLanding?(animating)
                guard !animating, let self else { return }
                landings += 1
                landing?.resume(returning: true)
                landing = nil
            }
            content.reset()
        }

        var sidebar: SidebarContainerView { root.sidebar }

        /// Pins Reduce Motion off and requires the springs to run here. A host where nothing animates fails
        /// the test; it does not pass with the spring checks skipped.
        func requireAnimates() throws {
            Motion.reduceMotionOverride = false
            try #require(Motion.canAnimate(in: root), "the window is on no screen or its display sleeps: nothing animates")
            try #require(Motion.sidebar.animatesMovement, "sidebar movement is off in this host's settings")
        }

        /// The toggle's turn: the model changes and the container applies it (`toggleSidebar`).
        func toggle(hidden: Bool) {
            sidebar.model.presentation = hidden ? .hidden : .shown
            sidebar.apply()
        }

        /// Waits for the width motion to end; false after `timeout`.
        func landed(timeout: Duration = .seconds(5)) async -> Bool {
            if !sidebar.isWidthAnimating { return true }
            return await withCheckedContinuation { continuation in
                landing = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.landing?.resume(returning: false)
                    self?.landing = nil
                }
            }
        }

        func close() {
            Motion.reduceMotionOverride = nil
            sidebar.restore(width: nil, presentation: .shown)
            window.orderOut(nil)
            window.close()
        }
    }

    static let springPrefix = "cmux.renderSpring."

    /// The `RenderSpring` springs on `layer`'s `keyPath` (`cmux.renderSpring.<serial>.<keyPath>`).
    static func springs(on layer: CALayer?, _ keyPath: String) -> [CASpringAnimation] {
        guard let layer else { return [] }
        return (layer.animationKeys() ?? []).filter { $0.hasPrefix(springPrefix) && $0.hasSuffix(".\(keyPath)") }
            .compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
    }

    /// Every `RenderSpring` spring on `layer`.
    static func allSprings(on layer: CALayer?) -> [String] {
        (layer?.animationKeys() ?? []).filter { $0.hasPrefix(springPrefix) }
    }

    /// The sum of the springs' start offsets on `layer`'s scalar `keyPath`: what shows at the springs' start
    /// is the model value plus this.
    static func startOffset(on layer: CALayer?, _ keyPath: String) -> CGFloat {
        springs(on: layer, keyPath).reduce(0) { $0 + CGFloat(($1.fromValue as? NSNumber)?.doubleValue ?? 0) }
    }

    /// `layer`'s frame minX in its superlayer at the springs' start (its springs on `position.x` and
    /// `bounds.size.width` added to the model values, at its anchor point).
    static func startMinX(of layer: CALayer) -> CGFloat {
        let x = layer.position.x + startOffset(on: layer, "position.x")
        let width = layer.bounds.width + startOffset(on: layer, "bounds.size.width")
        return x - layer.anchorPoint.x * width
    }

    /// A Chromium page drawn in its own child window (``ChildWindowContent``).
    final class FakePageWindowContent: NSView, ChildWindowContent {
        var drawsInChildWindow = true
    }

    /// Sets the collapse prototype for one test; the returned closure puts the previous one back.
    static func useCollapseMotion(_ variant: SidebarCollapseMotionVariant) -> () -> Void {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(SidebarTunables.all)
        let key = SidebarTunables.collapseMotion.key
        let previous = store.override(key)
        store.set(key, .choice(variant.rawValue))
        return { store.set(key, previous) }
    }

    @Test func registersTheSlideOnTheSidebar() {
        #expect(SidebarContainerView.renderServerMotions.map(\.kind) == [.sidebarSlide])
    }

    @Test func aHideSetsTheWidthOnceLaysOutOnceAndLandsOnce() async throws {
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let root = fixture.root, sidebar = fixture.sidebar
        let width = sidebar.frame.width, card = root.contentHost.frame
        try #require(width > 0)
        fixture.toggle(hidden: true)
        #expect(sidebar.widthConstraint.constant == 0, "the width constant is not set in the toggle's turn")
        #expect(sidebar.frame.width == 0, "the toggle's turn did not lay the window out at rest")
        #expect(abs(root.contentHost.frame.width - (card.width + width)) < 0.5)
        #expect(fixture.content.sizes.count == 1, "the content took \(fixture.content.sizes) in the toggle's turn")
        #expect(fixture.content.inMotion == [false], "a terminal would hold its grid instead of sending it now")
        #expect(fixture.content.layouts == 1)
        #expect(sidebar.isWidthAnimating && sidebar.widthMotionBackend == .renderServer)
        #expect(!root.isContentAreaInMotion, "the content is at rest through a render-server slide")
        #expect(root.contentHost.contentHold == nil, "a render-server slide holds no content width")
        #expect(fixture.landings == 0)
        // The card springs from where it showed: the old minus the new x, back to 0.
        let shift = card.minX - root.contentHost.frame.minX
        #expect(abs(Self.startOffset(on: root.contentHost.layer, "position.x") - shift) < 0.01)
        #expect(abs(Self.startOffset(on: root.mainPaneShade.shadeLayer, "position.x") - shift) < 0.01,
                "the shade's cut-out does not ride with the card")
        let landed = await fixture.landed()
        #expect(landed, "the slide did not land in 5 s")
        #expect(fixture.landings == 1)
        #expect(fixture.content.sizes.count == 1 && fixture.content.layouts == 1,
                "the slide resized or laid the content out again: \(fixture.content.sizes), \(fixture.content.layouts) layouts")
        #expect(sidebar.panel.isHidden, "a landed hide leaves the panel shown")
        #expect(Self.allSprings(on: root.contentHost.layer).isEmpty)
    }

    /// A show from rest hidden: the clip, the panel and the card start where they showed (the sidebar 0 wide),
    /// on either side.
    @Test func aShowStartsEveryLayerWhereItShowed() async throws {
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let root = fixture.root, sidebar = fixture.sidebar
        sidebar.restore(width: nil, presentation: .hidden)
        root.layoutSubtreeIfNeeded()
        let host = try #require(sidebar.superview)
        let clipBefore = sidebar.clip.convert(sidebar.clip.bounds, to: host).minX
        let panelBefore = sidebar.panel.convert(sidebar.panel.bounds, to: host).minX
        let cardBefore = root.contentHost.frame.minX
        fixture.content.reset()
        fixture.toggle(hidden: false)
        #expect(sidebar.frame.width > 0 && sidebar.widthConstraint.constant == sidebar.frame.width)
        #expect(fixture.content.sizes.count == 1 && fixture.content.inMotion == [false])
        let clipLayer = try #require(sidebar.clip.layer), panelLayer = try #require(sidebar.panel.layer)
        let clipStart = sidebar.frame.minX + Self.startMinX(of: clipLayer)
        #expect(abs(clipStart - clipBefore) < 0.01, "the clip starts at \(clipStart), it showed at \(clipBefore)")
        #expect(abs(Self.startOffset(on: clipLayer, "bounds.size.width") + sidebar.frame.width) < 0.01, "the clip starts 0 wide")
        let panelStart = clipStart + Self.startMinX(of: panelLayer)
        #expect(abs(panelStart - panelBefore) < 0.01, "the panel starts at \(panelStart), it showed at \(panelBefore)")
        let cardStart = root.contentHost.frame.minX + Self.startOffset(on: root.contentHost.layer, "position.x")
        #expect(abs(cardStart - cardBefore) < 0.01, "the card starts at \(cardStart), it showed at \(cardBefore)")
        #expect(Self.springs(on: clipLayer, "position.x").allSatisfy { $0.isAdditive && ($0.toValue as? NSNumber)?.doubleValue == 0 })
        let landed = await fixture.landed()
        #expect(landed && fixture.landings == 1 && !sidebar.panel.isHidden)
    }

    /// A toggle mid-slide adds one more additive spring from the old rest to the new one; the springs still
    /// running carry the velocity. The first slide's landing does nothing: the motion lands once, shown.
    @Test func aToggleMidSlideRetargetsAndLandsOnce() async throws {
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let root = fixture.root, sidebar = fixture.sidebar
        let card = root.contentHost.frame.minX
        fixture.toggle(hidden: true)
        let hidden = root.contentHost.frame.minX
        fixture.toggle(hidden: false)
        #expect(root.contentHost.frame.minX == card)
        let offsets = Self.springs(on: root.contentHost.layer, "position.x").map { CGFloat(($0.fromValue as? NSNumber)?.doubleValue ?? 0) }
        #expect(offsets.count == 2, "a retarget replaced the running spring: \(offsets)")
        // The hide's spring starts at (card - hidden), the show's at (hidden - card): together, the card shows where it was.
        #expect(abs(offsets.reduce(0, +)) < 0.01 && offsets.contains { abs($0 - (hidden - card)) < 0.01 },
                "the retarget does not start from the hide's rest: \(offsets)")
        #expect(fixture.content.sizes.count == 2, "one size per toggle: \(fixture.content.sizes)")
        #expect(sidebar.isWidthAnimating && fixture.landings == 0)
        let landed = await fixture.landed()
        #expect(landed && fixture.landings == 1)
        #expect(!sidebar.panel.isHidden, "the hide's landing collapsed the shown panel")
    }

    /// The gate off (Reduce Motion: no movement): the slide lands in the toggle's turn, once, with no spring.
    @Test func theGateOffLandsInTheTogglesTurn() throws {
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        Motion.reduceMotionOverride = true
        let root = fixture.root, sidebar = fixture.sidebar
        fixture.toggle(hidden: true)
        #expect(!sidebar.isWidthAnimating && fixture.landings == 1)
        #expect(sidebar.panel.isHidden && sidebar.frame.width == 0)
        #expect(fixture.content.sizes.count == 1 && fixture.content.layouts == 1)
        for layer in [root.contentHost.layer, sidebar.clip.layer, sidebar.panel.layer] {
            #expect(Self.allSprings(on: layer).isEmpty)
        }
    }

    /// The slide-and-fade variant fades the panel on the short fade tokens (`fadeIn` / `fadeOut`), not on the
    /// slide's spring, and the hide collapses the panel only once both the width and the fade landed.
    @Test func theFadeVariantFadesOnTheFadeTokens() async throws {
        let restoreMotion = Self.useCollapseMotion(.slideFade)
        defer { restoreMotion() }
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let sidebar = fixture.sidebar
        sidebar.restore(width: nil, presentation: .hidden)
        fixture.root.layoutSubtreeIfNeeded()
        fixture.toggle(hidden: false)
        let panel = try #require(sidebar.panel.layer)
        #expect(panel.opacity == 1)
        #expect(Self.springs(on: panel, "opacity").isEmpty, "the fade rides the slide's spring")
        let fadeIn = try #require(panel.animation(forKey: "opacity") as? CABasicAnimation, "the show does not fade")
        #expect(!(fadeIn is CASpringAnimation))
        #expect(abs(fadeIn.duration - Motion.sidebar.duration(MotionFade.fadeIn)) < 0.001, "the fade is not the fadeIn token")
        #expect((fadeIn.fromValue as? NSNumber)?.doubleValue == 0, "the show does not fade in from 0")
        let landed = await fixture.landed()
        #expect(landed && fixture.landings == 1)
        fixture.toggle(hidden: true)
        let fadeOut = try #require(panel.animation(forKey: "opacity") as? CABasicAnimation, "the hide does not fade")
        #expect(abs(fadeOut.duration - Motion.sidebar.duration(MotionFade.fadeOut)) < 0.001, "the fade is not the fadeOut token")
        #expect(panel.opacity == 0)
        let hid = await fixture.landed()
        #expect(hid && fixture.landings == 2 && sidebar.panel.isHidden)
    }

    /// A plain slide shows the panel opaque at once, also after a slide-and-fade hide left it transparent:
    /// no opacity animation, as on the main thread.
    @Test func aPlainShowAfterAFadeHideIsOpaqueAtOnce() async throws {
        var restoreMotion = Self.useCollapseMotion(.slideFade)
        defer { restoreMotion() }
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let sidebar = fixture.sidebar
        fixture.toggle(hidden: true)
        let hid = await fixture.landed()
        try #require(hid && sidebar.panel.isHidden && sidebar.panel.alphaValue == 0)
        restoreMotion()
        restoreMotion = Self.useCollapseMotion(.slide)
        fixture.toggle(hidden: false)
        #expect(sidebar.widthMotionBackend == .renderServer)
        #expect(sidebar.panel.alphaValue == 1 && sidebar.panel.layer?.opacity == 1)
        #expect(sidebar.panel.layer?.animation(forKey: "opacity") == nil && Self.springs(on: sidebar.panel.layer, "opacity").isEmpty,
                "the plain show fades in")
        let landed = await fixture.landed()
        #expect(landed && !sidebar.panel.isHidden)
    }

    /// The top row moves with the slide: the toolbar band starts where it showed (0 wide after the traffic
    /// lights with the sidebar hidden) and springs to its full width, and the leftmost strip's tabs start at
    /// the traffic-light inset they showed with, riding the card, so they never draw under the lights.
    @Test func aShowSpringsTheTopRowFromWhereItShowed() async throws {
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let root = fixture.root, sidebar = fixture.sidebar
        let strip = TabStripView.testing(model: TabStripModel(tabs: [TabItem(id: TabID("tab1"), title: "One")], selectedID: TabID("tab1")))
        strip.autoresizingMask = [.width, .minYMargin]
        fixture.content.addSubview(strip)
        root.topRowStripsSlide = {
            let slide = strip.windowControlsSlide()
            return { slide() }
        }
        sidebar.restore(width: nil, presentation: .hidden)
        root.layoutSubtreeIfNeeded()
        strip.frame = CGRect(x: 0, y: fixture.content.bounds.height - 36, width: fixture.content.bounds.width, height: 36)
        // sync-layout: the test reads the strip's inset with the sidebar hidden.
        strip.layoutSubtreeIfNeeded()
        let insetBefore = strip.windowControlsInset
        try #require(insetBefore > 0, "the strip is not under the traffic lights with the sidebar hidden")
        let band = try #require(root.toolbarBand.layer)
        let bandBefore = root.toolbarBand.frame
        let tabsBefore = strip.tabsClip.convert(strip.tabsClip.bounds, to: nil).minX
        let cardBefore = root.contentHost.frame.minX
        fixture.toggle(hidden: false)
        #expect(root.toolbarBand.frame.width > bandBefore.width, "the band is not at its full width in the toggle's turn")
        let bandStartWidth = band.bounds.width + Self.startOffset(on: band, "bounds.size.width")
        #expect(abs(bandStartWidth - bandBefore.width) < 0.5, "the band starts \(bandStartWidth) wide, it showed \(bandBefore.width)")
        let bandStartX = root.toolbarBand.frame.minX + Self.startOffset(on: band, "position.x")
            - band.anchorPoint.x * (bandStartWidth - band.bounds.width)
        #expect(abs(bandStartX - bandBefore.minX) < 0.5, "the band starts at \(bandStartX), it showed at \(bandBefore.minX)")
        #expect(abs(Self.startOffset(on: band, "opacity") + 1) < 0.01, "the band does not fade in with its presence")
        // At rest the strip is clear of the traffic lights; its tabs start where they showed, with the card.
        #expect(strip.windowControlsInset == 0)
        let clip = try #require(strip.tabsClip.layer)
        let cardShift = Self.startOffset(on: root.contentHost.layer, "position.x")
        let tabsStart = strip.tabsClip.convert(strip.tabsClip.bounds, to: nil).minX + cardShift
            + Self.startOffset(on: clip, "position.x") - clip.anchorPoint.x * Self.startOffset(on: clip, "bounds.size.width")
        #expect(abs(root.contentHost.frame.minX + cardShift - cardBefore) < 0.01)
        #expect(abs(tabsStart - tabsBefore) < 0.5, "the tabs start at \(tabsStart), they showed at \(tabsBefore) (under the lights)")
        let landed = await fixture.landed()
        #expect(landed && fixture.landings == 1)
        #expect(Self.allSprings(on: band).isEmpty && Self.allSprings(on: clip).isEmpty)
    }

    /// A Chromium page in its own child window follows the views' model frames, not a layer spring: the
    /// slide stays on the main thread's frames while one shows, as the layout's zoom does.
    @Test func aPageInAChildWindowKeepsTheSlideOnTheMainThread() throws {
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let root = fixture.root, sidebar = fixture.sidebar
        let page = FakePageWindowContent(frame: fixture.content.bounds)
        fixture.content.addSubview(page)
        defer { page.removeFromSuperview() }
        fixture.toggle(hidden: true)
        #expect(sidebar.widthMotionBackend == .cpuStep)
        #expect(sidebar.isWidthAnimating && root.isContentAreaInMotion)
        #expect(Self.allSprings(on: root.contentHost.layer).isEmpty && Self.allSprings(on: sidebar.clip.layer).isEmpty)
    }

    /// A restore during a render-server slide snaps every layer the slide moved, the window's card, shade
    /// and top row too: nothing keeps sliding apart from the sidebar's edge.
    @Test func aRestoreMidSlideStopsEverySpring() throws {
        let fixture = Fixture(renderServer: true)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let root = fixture.root, sidebar = fixture.sidebar
        fixture.toggle(hidden: true)
        try #require(!Self.allSprings(on: root.contentHost.layer).isEmpty)
        sidebar.restore(width: nil, presentation: .shown)
        let layers = [root.contentHost.layer, root.mainPaneShade.shadeLayer, root.toolbarBand.layer, sidebar.clip.layer, sidebar.panel.layer]
        for layer in layers {
            #expect(Self.allSprings(on: layer).isEmpty, "a spring kept running after the restore: \(Self.allSprings(on: layer))")
        }
        #expect(!sidebar.isWidthAnimating && !sidebar.panel.isHidden)
    }

    /// `motion.renderServer` off: the main thread animates the width constraint, holds the content and
    /// puts the window's content in motion, as before.
    @Test func theSwitchOffKeepsTheMainThreadSlide() throws {
        let fixture = Fixture(renderServer: false)
        defer { fixture.close() }
        try fixture.requireAnimates()
        let root = fixture.root, sidebar = fixture.sidebar
        fixture.toggle(hidden: true)
        #expect(sidebar.widthMotionBackend == .cpuStep)
        #expect(sidebar.isWidthAnimating && root.isContentAreaInMotion)
        #expect(root.contentHost.contentHold != nil)
        #expect(Self.allSprings(on: root.contentHost.layer).isEmpty)
    }
}
