import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
import Testing

/// With the feature `overlayTopLayer` and no page child window, a window's overlays
/// draw in its own top layer (the last subview of its content view), as Blink's top layer does: no overlay
/// panel is made, no child window is re-ordered, every overlay kind sits above a page attached as a view,
/// and a dialog keeps the keys it had in the panel. Page child windows still move the layer into the
/// panel (the fallback).
@MainActor @Suite(.serialized) struct OverlayTopLayerTests {
    /// A main window with the feature on.
    final class TopLayerWindow: NSWindow, OverlayTopLayerHosting {
        let overlaysInTopLayer = true
        // A main window takes the keyboard back when a modal ends; a borderless test window must be able to.
        override var canBecomeKey: Bool { true }

        // As the App's `ShellWindow` does: only a modal of the top layer takes the keyboard.
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if WindowOverlayHost.existingHost(for: self)?.refusesFirstResponder(responder) == true { return false }
            return super.makeFirstResponder(responder)
        }
    }

    /// A view that counts the moves its tracking area hears.
    final class MoveCounter: NSView {
        var moves = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func mouseMoved(with event: NSEvent) { moves += 1 }
    }

    /// A button that takes the keyboard whatever the Full Keyboard Access setting.
    final class KeyButton: NSButton {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct Fixture {
        let events = InputTapTestEvents()
        let window: TopLayerWindow
        let host: WindowOverlayHost
        /// Stands in for a Chromium page attached as a view, below the overlays.
        let page: NSView

        init(styleMask: NSWindow.StyleMask = [.borderless]) {
            _ = NSApplication.shared
            window = TopLayerWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400), styleMask: styleMask,
                                    backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            window.contentView = content
            page = NSView(frame: content.bounds)
            content.addSubview(page)
            window.orderFrontRegardless()
            window.makeKey()
            host = WindowOverlayHost.host(for: window)
            host.inputTap = events.tap
            host.pointerLocation = { NSPoint(x: -10_000, y: -10_000) }
        }

        func close() {
            host.tearDown()
            window.orderOut(nil)
        }
    }

    private static func view(_ width: CGFloat = 120, _ height: CGFloat = 60) -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    @Test func everyOverlayKindDrawsInTheWindowTopLayerWithNoPanel() throws {
        let f = Fixture()
        defer { f.close() }
        let anchor = NSRect(x: 100, y: 200, width: 40, height: 20)
        let kinds: [OverlayOptions] = [
            OverlayOptions(kind: .tooltip, anchor: anchor),
            OverlayOptions(kind: .toast),
            OverlayOptions(kind: .popover, anchor: anchor),
            OverlayOptions(kind: .menu, anchor: anchor),
            OverlayOptions(kind: .dragGhost, anchor: anchor),
            OverlayOptions(kind: .dialog, isModal: true, dimsContent: true, passesThroughClicks: false),
        ]
        let presented = kinds.map { (f.host.present(Self.view(), options: $0), $0.kind) }
        defer { presented.forEach { $0.0.dismiss() } }

        #expect(f.host.madePanel == nil, "a panel was made with no page child window")
        #expect((f.window.childWindows ?? []).isEmpty, "a child window was added")
        #expect(f.host.isTopLayerInWindow)
        let content = try #require(f.window.contentView)
        #expect(content.subviews.last === f.host.topLayer, "the top layer is not above the page")
        for (handle, kind) in presented {
            #expect(handle.content.window === f.window, "\(kind.rawValue) is not in the window")
            #expect(handle.content.isDescendant(of: f.host.topLayer), "\(kind.rawValue) is not in the top layer")
        }

        // A page child window event (the window's addChildWindow override calls this) re-orders nothing.
        WindowOverlayHost.childWindowsDidChange(of: f.window)
        #expect(f.host.reorderCount == 0)
        #expect(f.host.madePanel == nil)
    }

    @Test func aViewAddedLaterStaysBelowTheTopLayer() throws {
        let f = Fixture()
        defer { f.close() }
        let handle = f.host.present(Self.view(), options: OverlayOptions(kind: .toast))
        defer { handle.dismiss() }
        let content = try #require(f.window.contentView)
        // A page attached after the overlay showed (`WindowRootView` reports each add).
        let laterPage = Self.view(300, 300)
        content.addSubview(laterPage)
        f.host.contentViewDidAddSubview(laterPage)
        #expect(content.subviews.last === f.host.topLayer, "a later page covered the overlays")
        // A reorder that added nothing (`subviews =`): the layout pass repairs it.
        content.subviews = [f.host.topLayer, f.page, laterPage]
        #expect(f.host.repairAgentCursorOrder())
        #expect(content.subviews.last === f.host.topLayer)
    }

    @Test func onlyInteractiveOverlaysTakeTheMouseInTheWindow() throws {
        let f = Fixture()
        defer { f.close() }
        let content = try #require(f.window.contentView)
        let tooltip = f.host.present(Self.view(), options: OverlayOptions(kind: .tooltip, anchor: NSRect(x: 40, y: 300, width: 10, height: 10)))
        let popover = f.host.present(Self.view(), options: OverlayOptions(kind: .popover, anchor: NSRect(x: 300, y: 200, width: 10, height: 10)))
        defer {
            tooltip.dismiss()
            popover.dismiss()
        }
        let onPopover = NSPoint(x: popover.content.frame.midX, y: popover.content.frame.midY)
        let onTooltip = NSPoint(x: tooltip.content.frame.midX, y: tooltip.content.frame.midY)
        #expect(content.hitTest(onPopover)?.isDescendant(of: popover.content) == true, "the popover did not take its click")
        #expect(content.hitTest(onTooltip) === f.page, "the tooltip took a click meant for the page")
        #expect(content.hitTest(NSPoint(x: 580, y: 20)) === f.page, "the top layer took a click away from every overlay")

        let dialog = f.host.present(Self.view(), options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                         passesThroughClicks: false))
        defer { dialog.dismiss() }
        let blocked = try #require(content.hitTest(NSPoint(x: 580, y: 20)))
        #expect(blocked.isDescendant(of: f.host.topLayer), "a click reached the page under a modal")
    }

    @Test func aClickOnAnAgentCursorTagReachesItInTheWindow() throws {
        let f = Fixture()
        defer { f.close() }
        let tags = AgentCursorTagClickTests.Tags()
        f.host.agentCursorTags = tags
        _ = f.host.agentCursorLayer
        // A popover elsewhere: the full-size window and modal containers above the cursor are in place.
        let popover = f.host.present(Self.view(), options: OverlayOptions(kind: .popover, anchor: NSRect(x: 400, y: 100, width: 10, height: 10)))
        defer { popover.dismiss() }
        let content = try #require(f.window.contentView)
        let carrier = try #require(f.host.agentCursorCarrier)
        #expect(carrier.isDescendant(of: f.host.topLayer))
        withExtendedLifetime(tags) {
            // The tag is at (100, 50, 120, 22), y-down in the content view's coordinates.
            let onTag = NSPoint(x: 150, y: content.bounds.height - 61)
            #expect(content.hitTest(onTag) === carrier, "a container above the cursor took the tag's click")
            #expect(content.hitTest(NSPoint(x: 20, y: 20)) === f.page, "the cursor took a click off its tags")
        }
    }

    @Test func aClickInABlockingRegionWithNoOverlayViewEndsAtTheLayer() throws {
        let f = Fixture()
        defer { f.close() }
        let content = try #require(f.window.contentView)
        // A modal with no scrim: nothing of it is under the corner, and the page below must not get the click.
        let dialog = f.host.present(Self.view(), options: OverlayOptions(kind: .dialog, isModal: true, passesThroughClicks: false))
        defer { dialog.dismiss() }
        #expect(content.hitTest(NSPoint(x: 590, y: 10)) === f.host.topLayer)
    }

    @Test func aNonModalOverlayNeverTakesThePanesKeyboard() throws {
        let f = Fixture()
        defer { f.close() }
        let pane = KeyButton(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
        f.page.addSubview(pane)
        #expect(f.window.makeFirstResponder(pane))
        let content = Self.view()
        let button = KeyButton(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
        content.addSubview(button)
        let popover = f.host.present(content, options: OverlayOptions(kind: .popover, anchor: NSRect(x: 300, y: 200, width: 10, height: 10)))
        defer { popover.dismiss() }
        // A click on the popover's button asks the window to make it first responder: the window refuses.
        #expect(!f.window.makeFirstResponder(button), "a popover took the window's keyboard")
        #expect(f.window.firstResponder === pane)
        #expect(!f.host.keyboardIsInWindowTopLayer)

        // While a modal shows, the top layer has the keyboard, as the key panel had it.
        let dialog = Self.view(240, 120)
        let ok = KeyButton(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
        dialog.addSubview(ok)
        let modal = f.host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true, passesThroughClicks: false))
        #expect(f.window.firstResponder === ok)
        #expect(f.host.keyboardIsInWindowTopLayer)
        modal.dismiss()
        #expect(f.window.firstResponder === pane, "the keyboard did not go back to the pane")
    }

    @Test func aKeyboardMovedBesideATabDialogStaysWhenTheLayerMoves() throws {
        let f = Fixture()
        defer { f.close() }
        let pageField = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        f.page.addSubview(pageField)
        let dialog = Self.view(240, 120)
        let ok = KeyButton(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
        dialog.addSubview(ok)
        // A tab dialog: the rest of the window takes clicks.
        let handle = f.host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, passesThroughClicks: false,
                                                                    modalRegion: NSRect(x: 200, y: 100, width: 300, height: 250)))
        defer { handle.dismiss() }
        #expect(f.window.firstResponder === ok)
        // The person clicks into the page beside the dialog and types there.
        #expect(f.window.makeFirstResponder(pageField))
        // A page child window shows, then goes: the overlays move into the panel and back.
        f.host.setPlanesWantPanel(true)
        #expect(Self.focused(in: f.window) === pageField, "moving the layer into the panel took the keyboard")
        #expect(f.host.madePanel?.isKeyWindow != true)
        f.host.setPlanesWantPanel(false)
        #expect(Self.focused(in: f.window) === pageField, "moving the layer back took the keyboard")
    }

    @Test func aBlockingModalTurnsOffTheTrafficLights() throws {
        let f = Fixture(styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        defer { f.close() }
        let close = try #require(f.window.standardWindowButton(.closeButton))
        let zoom = try #require(f.window.standardWindowButton(.zoomButton))
        #expect(close.isEnabled)

        // A tab dialog leaves the rest of the window usable, the traffic lights too.
        let tab = f.host.present(Self.view(), options: OverlayOptions(kind: .dialog, isModal: true, passesThroughClicks: false,
                                                                      modalRegion: NSRect(x: 200, y: 100, width: 300, height: 250)))
        #expect(close.isEnabled)
        tab.dismiss()

        // A dimming modal blocks the whole window. The titlebar draws above the content view, so its buttons
        // are turned off instead of covered; one that was already off stays off after.
        zoom.isEnabled = false
        let dialog = f.host.present(Self.view(), options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                         passesThroughClicks: false))
        #expect(!close.isEnabled, "the close button takes clicks under a modal")
        #expect(f.window.standardWindowButton(.miniaturizeButton)?.isEnabled == false)
        dialog.dismiss()
        #expect(close.isEnabled)
        #expect(!zoom.isEnabled, "a button that was off came back on")
    }

    @Test func aHoverUnderTheLayerReachesOnlyTheLayer() throws {
        let f = Fixture()
        defer { f.close() }
        let below = MoveCounter(frame: f.page.bounds)
        f.page.addSubview(below)
        func move(_ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        // No overlay takes the point: the window sends the move on as usual.
        let toast = f.host.present(Self.view(), options: OverlayOptions(kind: .toast))
        defer { toast.dismiss() }
        #expect(!f.host.routeCoveredHover(try move(NSPoint(x: 20, y: 380))))

        let content = MoveCounter(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let dialog = f.host.present(content, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                     passesThroughClicks: false))
        defer { dialog.dismiss() }
        // On the scrim: handled here, so the view below never hears it.
        #expect(f.host.routeCoveredHover(try move(NSPoint(x: 5, y: 5))))
        #expect(content.moves == 0)
        // On the dialog: only the dialog's own tracking area hears it.
        #expect(f.host.routeCoveredHover(try move(content.convert(NSPoint(x: 100, y: 60), to: nil))))
        #expect(content.moves == 1)
        #expect(below.moves == 0)
    }

    @Test func aDialogKeepsItsKeysInTheWindow() throws {
        let f = Fixture()
        defer { f.close() }
        let before = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        f.page.addSubview(before)
        f.window.makeFirstResponder(before)

        let dialog = Self.view(240, 120)
        let field = NSTextField(frame: NSRect(x: 10, y: 70, width: 200, height: 22))
        let button = KeyButton(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
        dialog.addSubview(field)
        dialog.addSubview(button)
        let handle = f.host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dismissOnEscape: true,
                                                                    dimsContent: true, passesThroughClicks: false))
        #expect(f.host.madePanel == nil)
        #expect(f.host.keyboardIsInWindowTopLayer, "the dialog did not take the window's keyboard")
        let responder = try #require(f.window.firstResponder as? NSView)
        #expect(responder.isDescendant(of: dialog))

        // Tab cycles inside the dialog only, wrapping.
        #expect(WindowOverlayHost.keyViews(in: dialog) == [field, button])
        f.window.makeFirstResponder(field)
        #expect(f.host.cycleKeyViewInWindowTopLayer(forward: true))
        #expect(Self.focused(in: f.window) === button)
        #expect(f.host.cycleKeyViewInWindowTopLayer(forward: true))
        #expect(Self.focused(in: f.window) === field, "Tab left the dialog")

        // Escape on the button: the modal's intercept takes it for the window and sends it to the button,
        // whose responder chain reaches the top layer, which dismisses the dialog (the panel's `cancelOperation`).
        #expect(f.host.cycleKeyViewInWindowTopLayer(forward: true))
        #expect(Self.focused(in: f.window) === button)
        #expect(f.host.escapeEvent(try InputTapTestEvents.key(.keyDown, keyCode: 53, in: f.window)) == .consume)
        #expect(handle.isDismissed, "Escape did not dismiss the dialog")
        #expect(!f.host.keyboardIsInWindowTopLayer)
        #expect(Self.focused(in: f.window) === before, "the keyboard did not go back where it was")
    }

    @Test func pageChildWindowsMoveTheTopLayerIntoThePanelAndBack() throws {
        let f = Fixture()
        defer { f.close() }
        let toast = f.host.present(Self.view(), options: OverlayOptions(kind: .toast))
        defer { toast.dismiss() }
        #expect(f.host.isTopLayerInWindow)

        // The window layer reports a visible page child window: the fallback panel holds the overlays.
        f.host.setPlanesWantPanel(true)
        let panel = try #require(f.host.madePanel)
        #expect(f.host.isPanelAttached)
        #expect(f.host.topLayer.window === panel)
        #expect(toast.content.window === panel)
        #expect(!f.host.isTopLayerInWindow)

        // The page window went: the overlays come back into the window and the panel goes.
        f.host.setPlanesWantPanel(false)
        #expect(!f.host.isPanelAttached)
        #expect(f.host.isTopLayerInWindow)
        #expect(toast.content.window === f.window)
        #expect(f.window.contentView?.subviews.last === f.host.topLayer)
    }

    @Test func aModalTakesItsKeysAgainWhenItMovesIntoThePanel() throws {
        let f = Fixture()
        defer { f.close() }
        let dialog = Self.view(240, 120)
        let field = NSTextField(frame: NSRect(x: 10, y: 70, width: 200, height: 22))
        dialog.addSubview(field)
        let handle = f.host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                    passesThroughClicks: false))
        defer { handle.dismiss() }
        f.host.setPlanesWantPanel(true)
        let panel = try #require(f.host.madePanel)
        #expect(panel.acceptsKey, "the panel refuses the keyboard of the modal it holds")
        #expect((panel.firstResponder as? NSView)?.isDescendant(of: dialog) == true, "the modal lost the keyboard in the move")
        f.host.setPlanesWantPanel(false)
        #expect(!panel.acceptsKey)
        #expect(f.host.keyboardIsInWindowTopLayer, "the modal lost the keyboard on the way back")
    }

    @Test func withTheFeatureOffThePanelHoldsTheTopLayer() {
        let window = InputTapTestEvents.window()
        let host = WindowOverlayHost.host(for: window)
        host.inputTap = InputTapTestEvents().tap
        defer {
            host.tearDown()
            window.orderOut(nil)
        }
        let handle = host.present(Self.view(), options: OverlayOptions(kind: .toast))
        defer { handle.dismiss() }
        #expect(host.isPanelAttached)
        #expect(host.topLayer.window === host.madePanel)
        #expect(!host.isTopLayerInWindow)
    }

    /// The control with the keyboard (a text field for its field editor).
    private static func focused(in window: NSWindow) -> NSResponder? {
        let responder = window.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSResponder }
        return responder
    }
}
