@testable import CmuxNextDesign
import AppKit
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Testing

/// Leo 2026-11-24, of the closed-tab toast and the selection hint: "this ui is also there for the closed
/// recent tab thing and has the same pitfalls (wack ass glass, affected by layout shifts when it shouldnt
/// be, etc." An open tooltip or hover card keeps its place on screen while the layout under it shifts: it
/// moves only when the pointer takes another target. Before, a relayout that set a tooltip's text again
/// re-placed the tooltip under where its view had moved, and every geometry change carried a shown hover
/// card along with its target (`followShownTarget`).
@MainActor @Suite(.closesItsWindows, .serialized)
struct HoverSurfaceStaysPutTests {
    // MARK: Tooltip

    @Test func anOpenTooltipStaysPutWhenTheLayoutUnderItShifts() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = NSView(frame: NSRect(x: 40, y: 40, width: 60, height: 24))
        window.contentView?.addSubview(button)
        button.themedToolTip = "Reopen Closed Tab"
        window.orderFrontRegardless()
        let clock = ManualClock()
        let presenter = TooltipPresenter(clock: clock)
        presenter.timing = .standard
        defer {
            presenter.dismiss()
            presenter.panel.closeAfterTest()
            window.closeAfterTest()
        }
        let tracker = try #require(TooltipTracker.whole(of: button))
        presenter.enter(tracker)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(500))
        for _ in 0..<500 where presenter.shown == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10)) // test: the intent's deadline lands on the main actor
        }
        try #require(presenter.shown?.text == "Reopen Closed Tab", "the tooltip never showed")
        let opened = presenter.panel.frame

        // The layout shifts under the open tooltip: its view moves 40 pt and is configured again with the
        // same text, as a list or strip that relayouts its rows does.
        button.frame = button.frame.offsetBy(dx: 40, dy: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        button.themedToolTip = "Reopen Closed Tab"
        presenter.changed(tracker)
        let hold = AnchoredEdgeHold.sample(from: opened, step: {
            window.contentView?.layoutSubtreeIfNeeded()
            presenter.changed(tracker)
        }) { presenter.panel.isVisible ? presenter.panel.frame : nil }
        #expect(hold.held, "\(hold)")

        // New text shows where the tooltip is, centered on where it was placed, not on the moved view.
        button.themedToolTip = "Reopen Closed Tabs"
        presenter.changed(tracker)
        #expect(presenter.shown?.text == "Reopen Closed Tabs")
        #expect(abs(presenter.panel.frame.midX - opened.midX) <= AnchoredEdgeHold.tolerance,
                "new text moved the tooltip to its moved view: \(presenter.panel.frame) vs \(opened)")
    }

    // MARK: Hover card

    @MainActor
    private final class Source: HoverCardSource {
        let window: NSWindow
        var anchor: CGRect
        let target: HoverTarget
        init(window: NSWindow, anchor: CGRect, target: HoverTarget) {
            self.window = window
            self.anchor = anchor
            self.target = target
        }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at point: CGPoint) -> HoverCardHit? {
            anchor.contains(point) ? HoverCardHit(target: target, anchor: anchor) : nil
        }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { id == target.id ? anchor : nil }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            let body = NSTextField(labelWithString: "Closed “New Tab”\nReopen with ⇧⌘T")
            body.maximumNumberOfLines = 2
            return HoverCardBody(view: body, placement: .below, themeAnchor: nil) {}
        }
        func hoverCardActivated(_: HoverTargetID) {}
        func hoverCardDeactivated(_: HoverTargetID) {}
    }

    @Test func anOpenHoverCardStaysPutWhenTheLayoutUnderItShifts() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let target = HoverTarget(id: HoverTargetID("row:a"), window: window.windowNumber, delay: .zero,
                                 leave: .hides(reshow: HoverCardTiming.reshowWindow), enterable: true)
        let source = Source(window: window, anchor: CGRect(x: 200, y: 640, width: 180, height: 30), target: target)
        let coordinator = HoverCardCoordinator(clock: ManualClock())
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        coordinator.register(source)
        defer {
            coordinator.dismiss(.action)
            ([coordinator.panel] + coordinator.retiring).forEach { $0?.closeAfterTest() }
            window.close()
        }
        let pointer = CGPoint(x: source.anchor.midX, y: source.anchor.midY)
        coordinator.pointerMoved(to: pointer)
        try #require(coordinator.isShowing(target.id), "a move onto the target showed no card")
        let panel = try #require(coordinator.panel)
        let opened = panel.cardFrame

        // The layout shifts 40 pt under the open card; the pointer stays on the same target.
        source.anchor = source.anchor.offsetBy(dx: 40, dy: 0)
        try #require(source.anchor.contains(pointer), "the fixture needs the pointer still on its target")
        coordinator.geometryChanged(in: window)
        let hold = AnchoredEdgeHold.sample(from: opened, step: { coordinator.geometryChanged(in: window) }) {
            coordinator.isShowing(target.id) ? panel.cardFrame : nil
        }
        #expect(hold.held, "\(hold)")

        // The target gone, the card goes with it.
        source.anchor = .zero
        coordinator.geometryChanged(in: window)
        #expect(!coordinator.isShowing(target.id), "the card stayed for a target that is gone")
    }

    // MARK: The shared surface

    @Test func theHoverSurfacesDrawSolidByDefault() {
        #expect(HoverSurfaceLook.tunable.defaultValue == .hairline)
        #expect(HoverSurfaceLook.solidLooks.allSatisfy { $0.isSolid })
        #expect(!HoverSurfaceLook.glass.isSolid, "the glass stays reachable as the setting's other value")
        HoverSurfacePin.with(.hairline) {
            let tooltip = Glass.makeTooltipGlass()
            #expect(tooltip.materialOverride == .opaque)
            #expect(tooltip.castShadow == TooltipSurface.shadow)
            let card = HoverCardPanel()
            defer { card.closeAfterTest() }
            #expect(card.glass.material == .opaque)
            let toast = CmuxToastView(toast: CmuxToast(id: "t", message: "Closed “New Tab”", action: .undo()),
                                      reduceTransparency: ReduceTransparency(system: { false }, changes: NotificationCenter()))
            #expect(toast.surface?.material == .opaque, "the standard hint toast still draws glass")
        }
        HoverSurfacePin.with(.glass) {
            #expect(Glass.makeTooltipGlass().materialOverride == nil)
            let card = HoverCardPanel()
            defer { card.closeAfterTest() }
            #expect(card.glass.materialOverride == nil)
        }
    }

    @Test func eachSolidLookDrawsItsOwnEdgeAndShadow() {
        for look in HoverSurfaceLook.solidLooks {
            let surface = Glass.makeTooltipGlass(look: look)
            surface.frame = CGRect(x: 0, y: 0, width: 120, height: 24)
            #expect(surface.material == .opaque, "\(look)")
            #expect(surface.edgeWidth == look.edgeWidth, "\(look)")
            #expect(surface.castShadow == look.shadow(default: TooltipSurface.shadow), "\(look)")
        }
    }
}

/// Pins the shared hover surface's look (the `glass.hoverSurface` setting in the shared tunable store) for one
/// synchronous block, so a test of the glass or of a solid look does not depend on the default or a developer's
/// Debug Settings.
@MainActor
enum HoverSurfacePin {
    static func with(_ look: HoverSurfaceLook, _ body: () throws -> Void) rethrows {
        let store = TunableStore.shared
        store.register([HoverSurfaceLook.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let key = HoverSurfaceLook.tunable.key
        let before = store.overrides[key] // `set` returns the new value, not the old
        store.set(key, .choice(look.rawValue))
        defer { store.set(key, before) }
        try body()
    }
}
