import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// ZOOM VARIANTS 2, 2026-11-08 (zoom films, G4P): on Cmd-Shift-Enter the zooming pane grows over
/// a browser pane, and the browser's "Import cookies from Google Chrome" card stayed on top of the
/// growing pane for the whole motion, though the page under it was already cut away. The card is on
/// the window's overlay host, above every pane; the pane in front cuts only the page
/// (`PaneHostView.setStripClip`, read by `CEFClipShape`). A card whose place a pane in front covers
/// now leaves until the page shows that place again.
@MainActor @Suite(.serialized, .closesItsWindows) struct PageFloatingOverlaysCoverTests {
    struct Scene {
        let window: NSWindow
        let host: NSView
        let page: NSView
        let card: NSView
        let overlays: PageFloatingOverlays
        let notifications: NotificationCenter

        func close() {
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            window.isReleasedWhenClosed = false
            window.close()
            panel?.close()
        }

        /// A pane in front leaves `shown` of the page's pane and covers `cutouts` of it (host
        /// coordinates, top-down as a pane host's), as the column strip marks it
        /// (`PaneHostView.setStripClip`): a pane over a whole side narrows the frame, one over a
        /// middle part cuts a hole.
        func cover(_ cutouts: [CGRect], shown: CGRect? = nil) throws {
            let layer = try #require(host.layer)
            let mask = (layer.mask as? StripClipMaskLayer) ?? StripClipMaskLayer()
            mask.name = CALayer.cmuxStripClipName
            mask.place(shown ?? host.bounds, cutouts: cutouts, scale: 2)
            layer.mask = mask
        }

        /// What the frame step posts after a strip clip changed (`requestPageUpdate`).
        func pagesNeedUpdate() {
            notifications.post(name: .browserChildWindowPagesNeedUpdate, object: window)
        }
    }

    /// A pane host is top-down (`PaneHostView`): the card sits at its bottom, at large y.
    final class FlippedHost: NSView {
        override var isFlipped: Bool { true }
    }

    /// `cardWantsLayer` false: a card with no layer of its own (the notice pill, the link status bubble), as the
    /// cookie import card has one (`BrowserCookieImportCard`).
    static func scene(cardWantsLayer: Bool = true) throws -> Scene {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        content.wantsLayer = true
        let host = FlippedHost(frame: content.bounds)
        host.wantsLayer = true
        content.addSubview(host)
        let page = NSView(frame: host.bounds)
        host.addSubview(page)
        let card = NSView()
        card.wantsLayer = cardWantsLayer
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 300),
            card.heightAnchor.constraint(equalToConstant: 60),
        ])
        let notifications = NotificationCenter()
        let overlays = PageFloatingOverlays(page: page, notifications: notifications)
        overlays.add(card)
        return Scene(window: window, host: host, page: page, card: card, overlays: overlays, notifications: notifications)
    }

    @Test func aCardShowsOverItsUncoveredPage() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        scene.overlays.sync()
        #expect(scene.card.window != nil, "an uncovered page shows its card")
    }

    /// The zooming pane grows over the bottom of the page, where the card sits: the card leaves.
    @Test func aPaneInFrontOverTheCardsPlaceTakesTheCardOff() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        scene.overlays.sync()
        try #require(scene.card.window != nil)
        try scene.cover([CGRect(x: 0, y: 300, width: 800, height: 300)])
        scene.overlays.sync()
        #expect(scene.card.window == nil, "the card does not float over the pane in front of its page")
        #expect(scene.card.superview == nil)
    }

    /// A pane in front over another part of the page leaves the card where it is.
    @Test func aPaneInFrontElsewhereKeepsTheCard() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        try scene.cover([CGRect(x: 0, y: 0, width: 800, height: 200)])
        scene.overlays.sync()
        #expect(scene.card.window != nil)
    }

    /// A pane in front over only the card's place takes it off; when that pane leaves, the card
    /// comes back with its page.
    @Test func theCardComesBackWhenThePageShowsItsPlaceAgain() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        scene.overlays.sync()
        try scene.cover([CGRect(x: 200, y: 480, width: 400, height: 120)])
        scene.overlays.sync()
        #expect(scene.card.window == nil)
        try scene.cover([])
        scene.overlays.sync()
        #expect(scene.card.window != nil, "the card shows again with its page")
    }

    /// A pane in front over the whole bottom side narrows the page's clip (no hole): the card leaves,
    /// and comes back when the clip is whole again.
    @Test func aPaneInFrontOverTheCardsSideTakesTheCardOff() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        scene.overlays.sync()
        try scene.cover([], shown: CGRect(x: 0, y: 0, width: 800, height: 300))
        scene.overlays.sync()
        #expect(scene.card.window == nil, "the card does not float over the pane covering its side")
        try scene.cover([])
        scene.overlays.sync()
        #expect(scene.card.window != nil)
    }

    /// Zoom out: the frame step's page update alone brings the card back, in the frame the page
    /// shows its place again; nothing else has to sync it.
    @Test func theCardComesBackOnThePagesUpdateAlone() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        scene.overlays.sync()
        try scene.cover([CGRect(x: 0, y: 300, width: 800, height: 300)])
        scene.pagesNeedUpdate()
        #expect(scene.card.window == nil, "the zoom's page update takes the card off")
        try scene.cover([])
        scene.pagesNeedUpdate()
        #expect(scene.card.window != nil, "the zoom out's page update brings the card back at once")
    }

    /// Zoom out: the pane in front still covers the left part of the page and of the card. The card
    /// shows at once, cut the same way as its page, and takes no click over the pane in front.
    @Test func aPartlyCoveredCardShowsCutLikeItsPage() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        try scene.cover([], shown: CGRect(x: 450, y: 0, width: 350, height: 600))
        scene.overlays.sync()
        #expect(scene.card.window != nil, "the card shows with the part of its page that shows")
        #expect(scene.card.layer?.mask is StripClipMaskLayer, "the card is cut where the pane in front covers its page")
        #expect(scene.overlays.takesMouse(scene.card) != true, "no click on the card over the pane in front")
        try scene.cover([])
        scene.overlays.sync()
        #expect(scene.card.window != nil)
        #expect(scene.card.layer?.mask == nil, "a whole card has no cut")
    }

    /// Review of #38313: the notice pill and the link status bubble are cards with no layer of their own. Partly covered,
    /// such a card showed whole over the pane in front, and the notice took clicks there, as the cookie card did before.
    @Test func aPartlyCoveredCardWithNoLayerOfItsOwnShowsCutLikeItsPage() throws {
        let scene = try Self.scene(cardWantsLayer: false)
        defer { scene.close() }
        try scene.cover([], shown: CGRect(x: 450, y: 0, width: 350, height: 600))
        scene.overlays.sync()
        #expect(scene.card.window != nil, "the card shows with the part of its page that shows")
        #expect(scene.card.layer?.mask is StripClipMaskLayer, "the card is cut where the pane in front covers its page")
        #expect(scene.overlays.takesMouse(scene.card) != true, "no click on the card over the pane in front")
        try scene.cover([])
        scene.overlays.sync()
        #expect(scene.card.layer?.mask == nil, "a whole card has no cut")
    }
}
