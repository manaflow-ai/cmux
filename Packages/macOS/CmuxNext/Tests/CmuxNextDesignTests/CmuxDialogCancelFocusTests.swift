import AppKit
@testable import CmuxNextDesign
import Testing

/// Dogfood 2026-10-08 (C3, shots 02 and 03): a dialog is cancelled, and focus
/// and the overlay must come back right. However the cancel comes (Escape, a
/// click on Cancel, Command-period), the dialog leaves, the keyboard is back
/// in the field that had it, and nothing of the overlay stays: no scrim, no
/// panel taking the keyboard or the window's clicks.
@MainActor
@Suite(.serialized) struct CmuxDialogCancelFocusTests {
    init() { _ = NSApplication.shared }

    /// The agent pane's mode sheet: Cancel and a destructive Switch Mode, no default button.
    static let spec = CmuxDialogSpec(
        title: "Let the agent act without asking?", lines: ["Change fast-mode to on?"],
        buttons: [.cancel(), CmuxDialogButton(id: "switch", title: "Switch Mode", role: .destructive)])

    enum Cancel: String, CaseIterable, Sendable { case escape, click, commandPeriod }

    /// A window that can take the keyboard off screen and counts the times it was asked to.
    final class KeyWindow: NSWindow {
        var madeKey = 0
        override var canBecomeKey: Bool { true }
        override func makeKey() {
            madeKey += 1
            super.makeKey()
        }
    }

    /// The window with a focused field and the mode sheet showing on it (or on its pane).
    @MainActor final class Fixture {
        let main = KeyWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 22))
        let center = CmuxDialogCenter()
        var answer: CmuxDialogAnswer?
        var id = 0

        init(windowScope: Bool) {
            main.isReleasedWhenClosed = false
            main.orderFrontRegardless()
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            main.contentView?.addSubview(pane)
            pane.addSubview(field)
            main.makeFirstResponder(field)
            id = center.present(CmuxDialogCancelFocusTests.spec, in: windowScope ? .window(main) : .tab(pane)) { [weak self] in
                self?.answer = $0
            }
        }

        func close() {
            main.childWindows?.forEach { main.removeChildWindow($0); $0.orderOut(nil) }
            main.close()
        }

        func host() throws -> WindowOverlayHost { try #require(WindowOverlayHost.existingHost(for: main)) }
        func view() throws -> CmuxDialogView { try #require(center.view(id)) }

        func cancelButton() throws -> CmuxDialogButtonView {
            try #require(view().focusables.compactMap { $0 as? CmuxDialogButtonView }.first { $0.button.id == "cancel" })
        }

        func cancel(by cancel: Cancel) throws {
            let panel = try host().panel
            switch cancel {
            case .escape: panel.sendEvent(try CmuxDialogCancelFocusTests.key("\u{1b}", keyCode: 53, in: panel))
            case .click: try cancelButton().performClick(nil)
            case .commandPeriod:
                _ = panel.performKeyEquivalent(with: try CmuxDialogCancelFocusTests.key(".", keyCode: 47, modifiers: .command, in: panel))
            }
        }

        /// Cancel answered, the dialog left, nothing of the overlay stays, and the field has the keyboard.
        func expectCancelledAndRestored() throws {
            let host = try host()
            #expect(answer?.button == "cancel" && answer?.isDismissal == false, "Cancel answered the dialog")
            #expect(host.presentedHandles.isEmpty, "the dialog left")
            #expect(!CmuxDialogCancelFocusTests.hasScrim(host.panel.contentView), "no scrim stays over the window")
            #expect(!host.panel.canBecomeKey, "the overlay stops taking the keyboard")
            #expect(!host.acceptsMouse(at: NSPoint(x: 400, y: 300)), "the window takes its clicks again")
            #expect(CmuxDialogCancelFocusTests.owner(of: main.firstResponder) === field, "the field that had the keyboard has it again")
        }
    }

    /// Shot 02: Tab around the dialog to Cancel, then cancel.
    @Test(arguments: [false, true], Cancel.allCases)
    func cancellingAfterTabbingGivesTheKeyboardBackAndLeavesNothing(windowScope: Bool, cancel: Cancel) throws {
        let fixture = Fixture(windowScope: windowScope)
        defer { fixture.close() }
        let panel = try fixture.host().panel
        let view = try fixture.view()
        let cancelButton = try fixture.cancelButton()
        let cancelIndex = try #require(view.focusables.firstIndex { $0 === cancelButton })
        let start = view.focusedIndex
        for _ in view.focusables { panel.sendEvent(try Self.key("\t", keyCode: 48, in: panel)) }
        #expect(view.focusedIndex == start, "Tab goes round inside the dialog")
        for _ in view.focusables where view.focusedIndex != cancelIndex {
            panel.sendEvent(try Self.key("\t", keyCode: 48, in: panel))
        }
        #expect(view.focusedIndex == cancelIndex)
        try fixture.cancel(by: cancel)
        try fixture.expectCancelledAndRestored()
    }

    /// Leo's repro (shot 03): the dialog shows, the person uses another app and
    /// comes back, which makes the dialog's own window key again, then cancels.
    /// Coming back is not moving the focus: the window and its field get the
    /// keyboard back.
    @Test(arguments: [false, true], Cancel.allCases)
    func cancellingAfterComingBackFromAnotherAppGivesTheKeyboardBack(windowScope: Bool, cancel: Cancel) throws {
        let fixture = Fixture(windowScope: windowScope)
        defer { fixture.close() }
        Self.comeBack(to: fixture.main)
        fixture.main.madeKey = 0
        try fixture.cancel(by: cancel)
        try fixture.expectCancelledAndRestored()
        #expect(fixture.main.madeKey > 0, "the dialog's window takes the keyboard back")
    }

    /// Back from another app the window is key, so Escape reaches the window,
    /// not the dialog: the dialog still answers it, as its Cancel.
    @Test(arguments: [false, true])
    func escapeInTheWindowAfterComingBackCancelsTheDialog(windowScope: Bool) throws {
        let fixture = Fixture(windowScope: windowScope)
        defer { fixture.close() }
        Self.comeBack(to: fixture.main)
        let host = try fixture.host()
        #expect(host.routeEscape(try Self.key("\u{1b}", keyCode: 53, in: fixture.main), in: fixture.main))
        try fixture.expectCancelledAndRestored()
    }

    /// Escape in the window after the person clicked into another part of it
    /// (a tab dialog leaves the rest of the window usable) is that view's.
    @Test func escapeAfterTheFocusMovedInTheWindowIsNotTheDialogs() throws {
        let fixture = Fixture(windowScope: false)
        defer { fixture.close() }
        let other = NSTextField(frame: NSRect(x: 20, y: 60, width: 200, height: 22))
        fixture.main.contentView?.addSubview(other)
        fixture.main.makeFirstResponder(other)
        Self.comeBack(to: fixture.main)
        let host = try fixture.host()
        #expect(!host.routeEscape(try Self.key("\u{1b}", keyCode: 53, in: fixture.main), in: fixture.main))
        #expect(fixture.answer == nil, "the dialog stays")
        fixture.center.dismiss(fixture.id)
    }

    /// Back from another app the dialog's panel is not key: the first click on
    /// Cancel presses it, it does not only bring the panel forward.
    @Test func aDialogButtonTakesTheFirstClick() throws {
        let fixture = Fixture(windowScope: false)
        defer { fixture.close() }
        #expect(try fixture.cancelButton().acceptsFirstMouse(for: nil))
        fixture.center.dismiss(fixture.id)
    }

    /// What AppKit posts when the person leaves cmux and clicks its window to come back.
    static func comeBack(to window: NSWindow) {
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                    in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    static func hasScrim(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view is OverlayScrimView || view.subviews.contains { hasScrim($0) }
    }

    static func owner(of responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSResponder }
        return responder
    }
}
