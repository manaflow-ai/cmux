import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Review of #37296: (F1) the dialog's view took the keyboard itself, a plain view that refuses it, so
/// the page under it never got the keyboard and nobody could type into a text field; (F2) a tab switch
/// hid a tab's dialog and the next show asked the drawing for a new view, loading a page per switch
/// while the old one was never given back. The host now asks its drawing for one view per dialog,
/// hands the keyboard to the drawing on every show, and gives the view back only when the dialog ends.
@MainActor @Suite(.closesItsWindows) struct DialogOverlayDrawingTests {
    /// Counts what the host asks of its drawing.
    @MainActor private final class Drawing: CmuxDialogDrawing {
        var attached = 0, focused = 0, detached = 0
        func attach(_ dialog: CmuxDialogPresentation, in window: NSWindow?) -> NSView? {
            attached += 1
            return NSView()
        }
        func focus(_ dialog: CmuxDialogPresentation) { focused += 1 }
        func detach(_ dialog: CmuxDialogPresentation) { detached += 1 }
    }

    private static func window() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView?.addSubview(tab)
        return (window, tab)
    }

    @Test func aShownDialogGivesItsDrawingTheKeyboard() {
        let drawing = Drawing()
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: drawing, activate: {}, isAppActive: { true }))
        let (window, _) = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Rename", fields: [.text("name")], buttons: [.cancel(), .ok()]),
                                in: .window(window)) { _ in }
        #expect(drawing.attached == 1)
        #expect(drawing.focused == 1)
        center.dismiss(id)
        #expect(drawing.detached == 1)
    }

    @Test func aTabSwitchKeepsTheDialogsOneView() {
        let drawing = Drawing()
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: drawing, activate: {}, isAppActive: { true }))
        let (window, tab) = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Close tab?", buttons: [.cancel(), .ok()]), in: .tab(tab)) { _ in }
        for _ in 0..<3 {
            tab.isHidden = true
            tab.isHidden = false
        }
        // One view for the dialog's whole life, the keyboard back on each show, nothing given back early.
        #expect(drawing.attached == 1)
        #expect(drawing.focused == 4)
        #expect(drawing.detached == 0)
        center.dismiss(id)
        #expect(drawing.detached == 1)
    }

    /// Review 5 of #37296 (F1): an app-scope dialog's region was a fixed 520 x 420 points, so a card the
    /// interface scale made 570 points wide (380 px at 1.5) or a long dialog was clipped by the panel.
    @Test func anAppDialogsRegionGrowsToHoldItsCard() {
        let drawing = Drawing()
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: drawing, activate: {}, isAppActive: { true }))
        // An app dialog shows in the app overlay's own panel, which the dialog makes: the test closes it after the
        // dismiss (the panel is kept, not released, and orders in again for the next app overlay).
        defer { WindowOverlayHost.appHost().panel.closeAfterTest() }
        let id = center.present(CmuxDialogSpec(title: "Quit cmux?", buttons: [.cancel(), .ok()]), in: .app) { _ in }
        defer { center.dismiss(id) }
        guard let dialog = center.dialog(id), let view = dialog.view else {
            Issue.record("the app dialog has no view")
            return
        }
        #expect(view.frame.size == CmuxDialogOverlayHost.appRegion)
        dialog.cardRect = CGRect(x: 0, y: 0, width: 570, height: 600)
        #expect(view.frame.width >= 570 + CmuxDialogOverlayHost.appMargin * 2)
        #expect(view.frame.height >= 600 + CmuxDialogOverlayHost.appMargin * 2)
        // A card that fits leaves the least region.
        #expect(CmuxDialogOverlayHost.appRegion(holding: CGRect(x: 0, y: 0, width: 380, height: 200))
            == CmuxDialogOverlayHost.appRegion)
    }

    /// Holds each dialog's entrance until the test says its card drew.
    @MainActor private final class LateDrawing: CmuxDialogDrawing {
        var ready: (() -> Void)?
        func attach(_ dialog: CmuxDialogPresentation, in window: NSWindow?) -> NSView? { NSView() }
        func focus(_ dialog: CmuxDialogPresentation) {}
        func detach(_ dialog: CmuxDialogPresentation) {}
        func whenDrawn(_ dialog: CmuxDialogPresentation, _ ready: @escaping () -> Void) { self.ready = ready }
    }

    /// Reviews 7 and 11 of #37296: the host faded a dialog in while its page was still loading, and an app
    /// dialog with no window to wait in showed before its card painted. Every dialog is now presented at
    /// its transparent first frame, in its own panel, and fades in once its drawing says the card drew.
    @Test func aDialogFadesInOnlyOnceItsCardIsDrawn() {
        let drawing = LateDrawing()
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: drawing, activate: {}, isAppActive: { true }))
        let (window, _) = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Rename", buttons: [.cancel(), .ok()]), in: .window(window)) { _ in }
        defer { center.dismiss(id) }
        let view = center.dialog(id)?.view
        #expect(view?.window != nil)
        #expect(view?.layer?.opacity == 0)
        drawing.ready?()
        #expect(view?.layer?.opacity == 1)
    }

    /// Review 9 of #37296 (F1): capture exclusion goes on the window the dialog shows in, the overlay's.
    @Test func captureExclusionCoversTheOverlaysWindow() {
        let drawing = LateDrawing()
        let center = CmuxDialogCenter(host: CmuxDialogCaptureExcludedHost(
            inner: CmuxDialogOverlayHost(drawing: drawing, activate: {}, isAppActive: { true })))
        let (window, _) = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Password", buttons: [.cancel(), .ok()]), in: .window(window)) { _ in }
        let shownIn = center.dialog(id)?.window
        #expect(shownIn != nil)
        #expect(shownIn?.sharingType == NSWindow.SharingType.none)
        center.dismiss(id)
        #expect(shownIn?.sharingType != NSWindow.SharingType.none)
    }

    /// Review 20 of #37296 (F1): a center made with the default host (no drawing) kept a dialog registered
    /// but never shown, and giving the center a drawing host later left it there. The dialog moves to the
    /// new host and shows.
    @Test func aDialogShownBeforeTheDrawingIsWiredShowsOnceItIs() {
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: nil, activate: {}, isAppActive: { true }))
        let (window, _) = Self.window()
        defer { window.close() }
        let id = center.present(CmuxDialogSpec(title: "Close?", buttons: [.cancel(), .ok()]), in: .window(window)) { _ in }
        defer { center.dismiss(id) }
        #expect(center.dialog(id)?.view == nil)
        center.host = CmuxDialogOverlayHost(drawing: LateDrawing(), activate: {}, isAppActive: { true })
        #expect(center.dialog(id)?.view?.window != nil)
    }

    /// Review 23 of #37296 (F1): a narrow tab's dialog region grew past the tab and took clicks across its
    /// whole frame, so a click in the neighboring pane beside the card went into the transparent page. The
    /// region takes clicks only on its tab and its card.
    @Test func aGrownTabRegionTakesClicksOnlyOnItsTabAndCard() {
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: LateDrawing(), activate: {}, isAppActive: { true }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = NSView(frame: NSRect(x: 440, y: 0, width: 200, height: 480))
        window.contentView?.addSubview(tab)
        let id = center.present(CmuxDialogSpec(title: "Close?", buttons: [.cancel(), .ok()]), in: .tab(tab)) { _ in }
        defer { center.dismiss(id) }
        // The page lays out a 380 pt card: the region grows left over the neighboring pane (x 228...640).
        center.dialog(id)?.cardRect = CGRect(x: 16, y: 150, width: 380, height: 180)
        let overlay = WindowOverlayHost.host(for: window)
        #expect(!overlay.acceptsMouse(at: NSPoint(x: 300, y: 50)))
        #expect(overlay.acceptsMouse(at: NSPoint(x: 300, y: 240)))
        #expect(overlay.acceptsMouse(at: NSPoint(x: 500, y: 50)))
        // Review 25 (F2): the card is where the host placed the view, which it may clamp inside the window,
        // not at the region's origin: a click just inside the card's left edge is the card's.
        // The card spans the view's middle (y 150...330 of 480), flipped or not.
        let placed = center.dialog(id)?.view?.frame ?? .zero
        #expect(overlay.acceptsMouse(at: NSPoint(x: placed.minX + 17, y: placed.midY)))
        #expect(!overlay.acceptsMouse(at: NSPoint(x: placed.minX + 15, y: placed.midY)))
    }

    /// Review 32 of #37296 (F1): the panel took clicks only on each dialog's tab and card, but the newer
    /// dialog's view, grown over its neighbor, still covered the older dialog's card, so its transparent
    /// part took that card's clicks. A dialog's view takes only the clicks on its card.
    @Test func aNeighborsGrownDialogLeavesAnOlderCardItsClicks() {
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(drawing: LateDrawing(), activate: {}, isAppActive: { true }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let left = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 480))
        let right = NSView(frame: NSRect(x: 200, y: 0, width: 200, height: 480))
        window.contentView?.addSubview(left)
        window.contentView?.addSubview(right)
        let older = center.present(CmuxDialogSpec(title: "Close?", buttons: [.cancel(), .ok()]), in: .tab(left)) { _ in }
        defer { center.dismiss(older) }
        let newer = center.present(CmuxDialogSpec(title: "Quit?", buttons: [.cancel(), .ok()]), in: .tab(right)) { _ in }
        defer { center.dismiss(newer) }
        // Both regions grow to hold 380 pt cards: the older card is tall, the newer one short.
        center.dialog(older)?.cardRect = CGRect(x: 16, y: 20, width: 380, height: 440)
        center.dialog(newer)?.cardRect = CGRect(x: 16, y: 150, width: 380, height: 180)
        let olderView = center.dialog(older)?.view
        let newerView = center.dialog(newer)?.view
        let container = WindowOverlayHost.host(for: window).panel.modalContainer
        // Over the older card, under the newer view's transparent part (above its card, left of its tab).
        let point = NSPoint(x: 150, y: 440)
        #expect(newerView?.frame.contains(point) == true)
        #expect(container.hitTest(point) === olderView)
        #expect(container.hitTest(NSPoint(x: 300, y: 240)) === newerView)
    }

    /// Review 15 of #37296 (F2): a tab dialog's view was its tab's size, so in a narrow split the card was
    /// clipped. The region grows about the tab to hold the card, inside the window; a card that fits keeps
    /// the tab.
    @Test func aTabDialogsRegionHoldsACardWiderThanItsTab() {
        let tab = NSRect(x: 600, y: 100, width: 200, height: 300)
        let window = NSRect(x: 0, y: 0, width: 800, height: 600)
        let card = CGRect(x: 0, y: 0, width: 380, height: 180)
        let region = CmuxDialogOverlayHost.tabRegion(tab, holding: card, in: window)
        #expect(region.width >= 380 + CmuxDialogOverlayHost.tabMargin * 2)
        #expect(region.height == tab.height)
        // Kept inside the window: the tab is at its right edge.
        #expect(region.maxX <= window.maxX)
        #expect(region.contains(NSPoint(x: tab.midX, y: tab.midY)))
        #expect(CmuxDialogOverlayHost.tabRegion(NSRect(x: 0, y: 0, width: 600, height: 400), holding: card, in: window)
            == NSRect(x: 0, y: 0, width: 600, height: 400))
    }
}
