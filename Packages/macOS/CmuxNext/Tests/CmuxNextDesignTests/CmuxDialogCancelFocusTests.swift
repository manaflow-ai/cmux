import AppKit
@testable import CmuxNextDesign
import Testing

/// Dogfood 2026-10-08 (C3, shots 02 and 03): Tab to a dialog's Cancel, then
/// cancel it. However the cancel comes (Escape, a click on Cancel,
/// Command-period), the dialog leaves, the keyboard is back in the field that
/// had it, and nothing of the overlay stays: no scrim, no panel taking the
/// keyboard or the window's clicks.
@MainActor
@Suite(.serialized) struct CmuxDialogCancelFocusTests {
    init() { _ = NSApplication.shared }

    /// The agent pane's mode sheet: Cancel and a destructive Switch Mode, no default button.
    static let spec = CmuxDialogSpec(
        title: "Let the agent act without asking?", lines: ["Change fast-mode to on?"],
        buttons: [.cancel(), CmuxDialogButton(id: "switch", title: "Switch Mode", role: .destructive)])

    enum Cancel: String, CaseIterable, Sendable { case escape, click, commandPeriod }

    @Test(arguments: [false, true], Cancel.allCases)
    func cancellingAfterTabbingGivesTheKeyboardBackAndLeavesNothing(windowScope: Bool, cancel: Cancel) throws {
        let main = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        defer {
            main.childWindows?.forEach { main.removeChildWindow($0); $0.orderOut(nil) }
            main.close()
        }
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        try #require(main.contentView).addSubview(pane)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 22))
        pane.addSubview(field)
        main.makeFirstResponder(field)

        let center = CmuxDialogCenter()
        var answer: CmuxDialogAnswer?
        let id = center.present(Self.spec, in: windowScope ? .window(main) : .tab(pane)) { answer = $0 }
        let host = try #require(WindowOverlayHost.existingHost(for: main))
        let view = try #require(center.view(id))
        let cancelIndex = try #require(view.focusables.firstIndex { ($0 as? CmuxDialogButtonView)?.button.id == "cancel" })
        // Shot 02: the person moves the keyboard around the dialog, then lands on Cancel.
        let start = view.focusedIndex
        for _ in view.focusables {
            host.panel.sendEvent(try Self.key("\t", keyCode: 48, in: host.panel))
        }
        #expect(view.focusedIndex == start, "Tab goes round inside the dialog")
        for _ in view.focusables where view.focusedIndex != cancelIndex {
            host.panel.sendEvent(try Self.key("\t", keyCode: 48, in: host.panel))
        }
        #expect(view.focusedIndex == cancelIndex)

        switch cancel {
        case .escape:
            host.panel.sendEvent(try Self.key("\u{1b}", keyCode: 53, in: host.panel))
        case .click:
            try #require(view.focusables[cancelIndex] as? CmuxDialogButtonView).performClick(nil)
        case .commandPeriod:
            _ = host.panel.performKeyEquivalent(with: try Self.key(".", keyCode: 47, modifiers: .command, in: host.panel))
        }

        #expect(answer?.button == "cancel" && answer?.isDismissal == false, "Cancel answered the dialog")
        #expect(host.presentedHandles.isEmpty, "the dialog left")
        #expect(!Self.hasScrim(host.panel.contentView), "no scrim stays over the window")
        #expect(!host.panel.canBecomeKey, "the overlay stops taking the keyboard")
        #expect(!host.acceptsMouse(at: NSPoint(x: 400, y: 300)), "the window takes its clicks again")
        #expect(Self.owner(of: main.firstResponder) === field, "the keyboard is back in the field that had it")
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
