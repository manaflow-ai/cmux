import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// In-tree pages' overlay backend (plans/cmux-next/in-tree-pages.md, Overlays): with the mode on, a window's overlays
/// are plain views on top of its content view, not an `OverlayHostPanel`. A click goes by the window's own hit test,
/// from its frame view down, the way AppKit sends it; nothing is taken from below and no panel orders in. With the mode
/// off the same presenters use the panel, as before.
@MainActor @Suite(.closesItsWindows, .serialized) struct InTreeOverlayTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // A pane under the overlays: what a click outside every overlay must reach.
        let pane = NSView(frame: window.contentView?.bounds ?? .zero)
        pane.identifier = NSUserInterfaceItemIdentifier("pane")
        pane.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pane)
        window.orderFrontRegardless()
        return window
    }

    /// Runs `body` with in-tree pages on (an engine with the calls), and turns the mode back off after it.
    private static func inTree<T>(_ on: Bool = true, _ body: () throws -> T) rethrows -> T {
        InTreePages.shared.setForTesting(requested: on, engine: on ? .supported : .unknown)
        defer { InTreePages.shared.setForTesting(requested: false) }
        return try body()
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    private static let spec = CmuxDialogSpec(
        title: "Close \u{201C}IOS INTERNAL CI\u{201D}?", lines: ["Still running: claude."],
        fields: [.check(id: "dont-ask-again", title: "Don\u{2019}t ask again", on: false)],
        buttons: [.cancel("Cancel"), CmuxDialogButton(id: "confirm", title: "Close", role: .destructive)],
        identifier: "cmux.dialog.confirmation")

    /// The window's own hit test at `point` (window coordinates), from its frame view: what AppKit sends a click to.
    private static func hit(_ window: NSWindow, at point: NSPoint) -> NSView? {
        guard let frame = window.contentView?.superview else { return nil }
        return frame.hitTest(frame.convert(point, from: nil))
    }

    private static func middle(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    private static func visiblePanels(of window: NSWindow) -> [NSWindow] {
        (window.childWindows ?? []).filter { $0 is OverlayHostPanel && $0.isVisible }
    }

    @Test func aDialogShowsOnTheWindowItselfWithNoPanel() throws {
        try Self.inTree {
            let window = Self.window()
            defer { window.close() }
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let id = center.present(Self.spec, in: .window(window)) { _ in }
            defer { center.dismiss(id) }
            let card = try #require(center.dialog(id)?.view)
            let host = try #require(WindowOverlayHost.existingHost(for: window))
            #expect(card.window === window, "the card is in \(card.window.map { String(describing: type(of: $0)) } ?? "no window")")
            #expect(host.isRootInWindow)
            #expect(window.contentView?.subviews.last === host.panel.root, "the overlays are not on top of the window's content")
            #expect(Self.visiblePanels(of: window).isEmpty, "an overlay panel ordered in")
        }
    }

    @Test func everyControlOfTheCardIsWhatTheWindowsHitTestFinds() throws {
        try Self.inTree {
            let window = Self.window()
            defer { window.close() }
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let id = center.present(Self.spec, in: .window(window)) { _ in }
            defer { center.dismiss(id) }
            let card = try #require(center.dialog(id)?.view)
            card.layoutSubtreeIfNeeded()
            for name in ["cmux.dialog.button.confirm", "cmux.dialog.button.cancel", "cmux.dialog.field.dont-ask-again"] {
                let control = try #require(Self.all(card).first { $0.identifier?.rawValue == name })
                let hit = Self.hit(window, at: Self.middle(of: control))
                #expect(hit.map { $0 === control || $0.isDescendant(of: control) } == true,
                        "\(name): the click hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
        }
    }

    @Test func aClickOnCloseAnswersClose() throws {
        try Self.inTree {
            let window = Self.window()
            defer { window.close() }
            var answer: CmuxDialogAnswer?
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let id = center.present(Self.spec, in: .window(window)) { answer = $0 }
            defer { center.dismiss(id) }
            let card = try #require(center.dialog(id)?.view)
            card.layoutSubtreeIfNeeded()
            let close = try #require(Self.all(card).first { $0.identifier?.rawValue == "cmux.dialog.button.confirm" })
            var reached = Self.hit(window, at: Self.middle(of: close))
            while let view = reached, !(view is NSControl) { reached = view.superview }
            let control = try #require(reached as? NSControl)
            #expect(control === close)
            control.performClick(nil)
            #expect(answer?.button == "confirm")
        }
    }

    /// A dimming dialog blocks the whole window: a click beside the card reaches no pane under it.
    @Test func aDimmingDialogTakesEveryClickOfTheWindow() throws {
        try Self.inTree {
            let window = Self.window()
            defer { window.close() }
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let id = center.present(Self.spec, in: .window(window)) { _ in }
            defer { center.dismiss(id) }
            let hit = Self.hit(window, at: NSPoint(x: 10, y: 10))
            #expect(hit.map { $0.identifier?.rawValue == "pane" } != true, "a click beside a dimming dialog reached the pane")
        }
    }

    /// A toast takes the mouse over itself only: beside it the pane under the overlays gets the click.
    @Test func outsideANonModalOverlayThePaneTakesTheClick() throws {
        try Self.inTree {
            let window = Self.window()
            defer { window.close() }
            let host = WindowOverlayHost.host(for: window)
            let toast = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
            let handle = host.present(toast, options: OverlayOptions(kind: .toast, anchor: NSRect(x: 600, y: 400, width: 1, height: 1)))
            defer { handle.dismiss() }
            let onToast = Self.hit(window, at: Self.middle(of: toast))
            #expect(onToast.map { $0 === toast || $0.isDescendant(of: toast) } == true,
                    "a click on the toast hits \(onToast.map { String(describing: type(of: $0)) } ?? "nothing")")
            let beside = Self.hit(window, at: NSPoint(x: 20, y: 20))
            #expect(beside?.identifier?.rawValue == "pane", "a click beside the toast hits \(beside.map { String(describing: type(of: $0)) } ?? "nothing")")
            #expect(Self.visiblePanels(of: window).isEmpty)
        }
    }

    /// Nothing is taken from below in the mode: the window's own dispatch is the only route.
    @Test func noEventIsTakenFromBelow() throws {
        try Self.inTree {
            let window = Self.window()
            defer { window.close() }
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let id = center.present(Self.spec, in: .window(window)) { _ in }
            defer { center.dismiss(id) }
            let card = try #require(center.dialog(id)?.view)
            let before = InTreeRetiredGuards.shared.takeEventFromBelow
            let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: Self.middle(of: card), modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(!WindowOverlayHost.takeEventFromBelow(press, in: window))
            #expect(InTreeRetiredGuards.shared.takeEventFromBelow == before)
        }
    }

    /// A modal overlay takes the window's own first responder; the window stays the key candidate.
    @Test func aModalDialogTakesTheWindowsFirstResponder() throws {
        try Self.inTree {
            let window = Self.window()
            defer { window.close() }
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let id = center.present(Self.spec, in: .window(window)) { _ in }
            defer { center.dismiss(id) }
            let host = try #require(WindowOverlayHost.existingHost(for: window))
            let responder = window.firstResponder as? NSView
            #expect(responder.map { $0.isDescendant(of: host.panel.root) } == true,
                    "the window's first responder is \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        }
    }

    /// The overlays leave the window with the last one; the root goes back where it was.
    @Test func theRootLeavesTheWindowWithTheLastOverlay() throws {
        try Self.inTree {
            let window = Self.window()
            defer { window.close() }
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let id = center.present(Self.spec, in: .window(window)) { _ in }
            let host = try #require(WindowOverlayHost.existingHost(for: window))
            center.dismiss(id)
            host.endStaleFades()
            host.syncPanel()
            if host.fadingOut == 0 { #expect(!host.isRootInWindow, "the overlay root stays on the window with no overlay") }
            #expect(Self.visiblePanels(of: window).isEmpty)
        }
    }

    /// With the mode off the dialog shows in the overlay panel, as today.
    @Test func withTheModeOffTheDialogShowsInThePanel() throws {
        try Self.inTree(false) {
            let window = Self.window()
            defer { window.close() }
            let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
            let id = center.present(Self.spec, in: .window(window)) { _ in }
            defer { center.dismiss(id) }
            let card = try #require(center.dialog(id)?.view)
            #expect(card.window is OverlayHostPanel)
            #expect(WindowOverlayHost.existingHost(for: window)?.isRootInWindow == false)
        }
    }
}
