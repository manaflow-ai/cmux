import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Testing

/// ZOOM VARIANTS 2, 2026-11-08 (zoom films, G4P): on Cmd-Shift-Enter the zooming pane grows over
/// a browser pane, and the browser's "Import cookies from Google Chrome" card stayed on top of the
/// growing pane for the whole motion, though the page under it was already cut away. The card is on
/// the window's overlay host, above every pane; the pane in front cuts only the page
/// (`PaneHostView.setStripClip`, read by `CEFClipShape`). A card whose place a pane in front covers
/// now leaves until the page shows that place again.
@MainActor @Suite(.serialized) struct PageFloatingOverlaysCoverTests {
    struct Scene {
        let window: NSWindow
        let host: NSView
        let page: NSView
        let card: NSView
        let overlays: PageFloatingOverlays

        func close() {
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            window.isReleasedWhenClosed = false
            window.close()
            panel?.close()
        }

        /// A pane in front covers `cutouts` of the page's pane (host coordinates), as the column
        /// strip marks it (`PaneHostView.setStripClip`).
        func cover(_ cutouts: [CGRect]) throws {
            let layer = try #require(host.layer)
            let mask = (layer.mask as? StripClipMaskLayer) ?? StripClipMaskLayer()
            mask.name = CALayer.cmuxStripClipName
            mask.place(host.bounds, cutouts: cutouts, scale: 2)
            layer.mask = mask
        }
    }

    static func scene() throws -> Scene {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        content.wantsLayer = true
        let host = NSView(frame: content.bounds)
        host.wantsLayer = true
        content.addSubview(host)
        let page = NSView(frame: host.bounds)
        host.addSubview(page)
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 300),
            card.heightAnchor.constraint(equalToConstant: 60),
        ])
        let overlays = PageFloatingOverlays(page: page)
        overlays.add(card)
        return Scene(window: window, host: host, page: page, card: card, overlays: overlays)
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
        try scene.cover([CGRect(x: 0, y: 0, width: 800, height: 300)])
        scene.overlays.sync()
        #expect(scene.card.window == nil, "the card does not float over the pane in front of its page")
        #expect(scene.card.superview == nil)
    }

    /// A pane in front over another part of the page leaves the card where it is.
    @Test func aPaneInFrontElsewhereKeepsTheCard() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        try scene.cover([CGRect(x: 0, y: 400, width: 800, height: 200)])
        scene.overlays.sync()
        #expect(scene.card.window != nil)
    }

    /// A pane in front over only the card's place takes it off; when that pane leaves, the card
    /// comes back with its page.
    @Test func theCardComesBackWhenThePageShowsItsPlaceAgain() throws {
        let scene = try Self.scene()
        defer { scene.close() }
        scene.overlays.sync()
        try scene.cover([CGRect(x: 200, y: 0, width: 400, height: 120)])
        scene.overlays.sync()
        #expect(scene.card.window == nil)
        try scene.cover([])
        scene.overlays.sync()
        #expect(scene.card.window != nil, "the card shows again with its page")
    }
}
