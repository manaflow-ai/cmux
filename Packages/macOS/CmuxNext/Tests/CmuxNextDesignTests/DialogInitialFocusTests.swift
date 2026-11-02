import AppKit
@testable import CmuxNextDesign
import Testing

/// QA chrome-parity-v2-1 (multi-line paste confirm): the dialog opened with the keyboard on its
/// Deny button, so a person typing on ("seq 1 10") had the Space press Deny, and the paste was
/// lost. A dialog opening never puts the keyboard on a button the person did not choose: Space
/// presses nothing until Tab (or a click) moves to a button, while Return still presses the
/// default button and Escape the cancel one.
@MainActor @Suite(.serialized) struct DialogInitialFocusTests {
    /// The paste confirm's shape: Deny (Escape), then Allow (Return).
    nonisolated static let paste = CmuxDialogSpec(title: "Paste into the terminal?", buttons: [
        CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
        CmuxDialogButton(id: "allow", title: "Allow", role: .default),
    ])
    /// A destructive default: Return closes, a typed Space must not.
    nonisolated static let close = CmuxDialogSpec(title: "Close the running terminal?", buttons: [
        .cancel(), CmuxDialogButton(id: "close", title: "Close", role: .default),
    ])
    /// No default at all: Escape is the only key.
    nonisolated static let noDefault = CmuxDialogSpec(title: "Allow a program to read the clipboard?", buttons: [
        CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
        CmuxDialogButton(id: "allow", title: "Allow"),
    ])

    private static func shown(_ spec: CmuxDialogSpec) -> (NSWindow, CmuxDialogView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let dialog = CmuxDialogView(spec: spec)
        window.contentView?.addSubview(dialog)
        dialog.focusInitial()
        return (window, dialog)
    }

    private static func key(_ characters: String, code: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// The key goes where AppKit sends a key down: the window's first responder.
    private static func type(_ event: NSEvent, in window: NSWindow) throws {
        let responder = try #require(window.firstResponder)
        responder.keyDown(with: event)
    }

    @Test(arguments: [paste, close, noDefault])
    func aTypedSpaceAsTheDialogOpensPressesNoButton(_ spec: CmuxDialogSpec) throws {
        let (window, dialog) = Self.shown(spec)
        defer { window.close() }
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        #expect(!(window.firstResponder is CmuxDialogButtonView), "the dialog opened with the keyboard on a button")
        #expect(dialog.containsKeyboard, "the dialog does not hold the keyboard")
        for (character, code) in [("s", 1), (" ", 49), ("1", 18)] as [(String, UInt16)] {
            try Self.type(Self.key(character, code: code, in: window), in: window)
        }
        #expect(pressed.isEmpty, "typing on pressed \(pressed)")
    }

    @Test(arguments: [paste, close])
    func returnStillPressesTheDefaultButton(_ spec: CmuxDialogSpec) throws {
        let (window, dialog) = Self.shown(spec)
        defer { window.close() }
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        try Self.type(Self.key("\r", code: 36, in: window), in: window)
        #expect(pressed == [spec.defaultButton?.id].compactMap { $0 })
    }

    @Test(arguments: [paste, close, noDefault])
    func escapeStillPressesTheCancelButton(_ spec: CmuxDialogSpec) throws {
        let (window, dialog) = Self.shown(spec)
        defer { window.close() }
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        try Self.type(Self.key("\u{1b}", code: 53, in: window), in: window)
        #expect(pressed == [spec.cancelButton?.id].compactMap { $0 })
    }

    /// Tab moves the keyboard onto the first button; Space then presses the button the person chose.
    @Test func afterTabSpacePressesTheChosenButton() throws {
        let (window, dialog) = Self.shown(Self.paste)
        defer { window.close() }
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        try Self.type(Self.key("\t", code: 48, in: window), in: window)
        #expect((window.firstResponder as? CmuxDialogButtonView)?.button.id == "deny")
        try Self.type(Self.key(" ", code: 49, in: window), in: window)
        #expect(pressed == ["deny"])
    }

    /// A dialog with a text field still opens typing into it.
    @Test func aTextFieldStillTakesTheKeyboard() throws {
        let spec = CmuxDialogSpec(title: "Rename Workspace", fields: [
            .text(id: "name", label: nil, initial: "", placeholder: "Name", secure: false),
        ], buttons: [.cancel(), .ok("Rename")])
        let (window, dialog) = Self.shown(spec)
        defer { window.close() }
        #expect(dialog.focusedIndex == 0, "the name field does not have the keyboard")
    }
}
