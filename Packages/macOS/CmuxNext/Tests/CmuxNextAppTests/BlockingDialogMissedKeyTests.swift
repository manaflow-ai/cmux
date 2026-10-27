import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// QA chrome-parity-v2-1 and journey paste-confirm-keys: the multi-line paste confirm is a tab
/// dialog over the terminal it blocks. When its overlay did not have the keyboard (the app was not
/// active as it opened, the person came back to the window, or automation sent the key to the
/// window), only Escape answered it (`cancelsBlockingDialog`); Return and a typed line went to the
/// terminal under it (awk printed an empty `got-`). A key that is not a chord and missed the
/// dialog blocking where it landed goes to the dialog keyboard (`CmuxDialogKeys`), never to the view
/// under it. A key elsewhere, a chord, and a key for the dialog's own controls keep their routes.
@MainActor @Suite(.serialized) struct BlockingDialogMissedKeyTests {
    private final class TabView: NSView {
        var keys: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys.append(event.characters ?? "") }
    }

    private struct Fixture {
        let services: AppServices
        let window: NSWindow
        let tab: TabView
        let other: TabView
        var router: KeyRouter { services.keyRouter }
        func close() {
            CmuxDialogCenter.shared.dismissAll()
            window.close()
        }
    }

    private static func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = TabView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let other = TabView(frame: NSRect(x: 320, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(tab)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(tab)
        try #require(window.firstResponder === tab)
        return Fixture(services: services, window: window, tab: tab, other: other)
    }

    /// The paste confirm's shape: Deny (Escape), Allow (Return).
    private static let spec = CmuxDialogSpec(title: "Paste into the terminal?", buttons: [
        CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
        CmuxDialogButton(id: "allow", title: "Allow", role: .default),
    ], identifier: "cmux.dialog.terminalClipboard")

    private static var timestamp: TimeInterval = 7000

    private static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                            in window: NSWindow) throws -> NSEvent {
        timestamp += 1
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                             windowNumber: window.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// The router's decision for `event` in `window`, as `CmuxApplication.sendEvent` and `debug.key` run it.
    private static func dispatch(_ event: NSEvent, in window: NSWindow, _ f: Fixture) -> Bool {
        f.router.dispatchingSynthetic(event) { f.router.interceptKeyDown(event, in: window) }
    }

    @Test func returnThatMissedTheBlockingDialogPressesItsDefaultButton() throws {
        let f = try Self.fixture()
        defer { f.close() }
        var answers: [String?] = []
        CmuxDialogCenter.shared.present(Self.spec, in: .tab(f.tab)) { answers.append($0.button) }
        try #require(CmuxDialogCenter.shared.records.contains { $0.spec.identifier == Self.spec.identifier && $0.visible })

        #expect(Self.dispatch(try Self.key("\r", code: 36, in: f.window), in: f.window, f), "the Return went on to the view under the dialog")
        #expect(answers == ["allow"])
    }

    @Test func aTypedLineThatMissedTheBlockingDialogNeverReachesTheViewUnderIt() throws {
        let f = try Self.fixture()
        defer { f.close() }
        var answers: [String?] = []
        CmuxDialogCenter.shared.present(Self.spec, in: .tab(f.tab)) { answers.append($0.button) }

        for (character, code) in [("s", 1), ("e", 14), (" ", 49), ("1", 18)] as [(String, UInt16)] {
            #expect(Self.dispatch(try Self.key(character, code: code, in: f.window), in: f.window, f),
                    "\(character.debugDescription) went on to the view under the dialog")
        }
        #expect(answers.isEmpty, "a typed key answered the dialog: \(answers)")
        // Escape still denies (the missed-modal Escape route).
        #expect(Self.dispatch(try Self.key("\u{1b}", code: 53, in: f.window), in: f.window, f))
        #expect(answers == ["deny"])
    }

    @Test func keysElsewhereChordsAndTheDialogsOwnKeysKeepTheirRoutes() throws {
        let f = try Self.fixture()
        defer { f.close() }
        var answers: [String?] = []
        let id = CmuxDialogCenter.shared.present(Self.spec, in: .tab(f.tab)) { answers.append($0.button) }

        // A Command chord is the menu's and the app's (Cmd-W, Cmd-Q), as before.
        #expect(!Self.dispatch(try Self.key("x", code: 7, modifiers: .command, in: f.window), in: f.window, f))
        // The dialog's own window, with the keyboard in the dialog: AppKit delivers the key to its controls.
        let dialog = try #require(CmuxDialogCenter.shared.view(id))
        let dialogWindow = try #require(dialog.window)
        dialogWindow.makeFirstResponder(dialog)
        #expect(!Self.dispatch(try Self.key("\r", code: 36, in: dialogWindow), in: dialogWindow, f),
                "the router took a key the dialog has the keyboard for")
        // Another view of the window has the keyboard: the tab's dialog does not block it.
        f.window.makeFirstResponder(f.other)
        try #require(f.window.firstResponder === f.other)
        #expect(!Self.dispatch(try Self.key("a", code: 0, in: f.window), in: f.window, f), "a key outside the blocked tab was taken")
        #expect(answers.isEmpty)
    }
}
