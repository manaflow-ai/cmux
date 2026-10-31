import AppKit
import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// Cmd+Shift+V is Edit > Paste and Match Style (Lawrence 2026-10-20: "Command+Shift+V
/// works to paste things as just raw text in the iMessage UI"). The item sends
/// `pasteAsPlainText(_:)` down the responder chain, so every text input (the Home
/// message box, the agent chat's web composer, search fields) pastes plain text,
/// and Cmd+V stays Paste.
@MainActor @Suite(.closesItsWindows) struct PasteAndMatchStyleMenuTests {
    @MainActor private final class Probe: NSView {
        var runs: [String] = []
        @objc func pasteAsPlainText(_ sender: Any?) { runs.append("plain") }
        @objc func paste(_ sender: Any?) { runs.append("paste") }
    }

    /// Chromium's page view (`RenderWidgetHostViewCocoa`): it answers Chrome's
    /// `pasteAndMatchStyle:`, never AppKit's `pasteAsPlainText:`.
    @MainActor private final class ChromiumPageProbe: NSView {
        var runs: [String] = []
        override var acceptsFirstResponder: Bool { true }
        @objc func pasteAndMatchStyle(_ sender: Any?) { runs.append("matchStyle") }
    }

    /// A page view with nothing to paste into: it validates Chrome's selector off, as
    /// `RenderWidgetHostViewCocoa` does where Chrome disables Paste and Match Style.
    @MainActor private final class ReadOnlyChromiumPageProbe: NSView, NSUserInterfaceValidations {
        override var acceptsFirstResponder: Bool { true }
        @objc func pasteAndMatchStyle(_ sender: Any?) {}
        func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            item.action != Selector(("pasteAndMatchStyle:"))
        }
    }

    private func editMenu() throws -> NSMenu {
        _ = NSApplication.shared
        let bar = MainMenu.make(registry: ActionRegistry.standard(), blocking: .forProcess())
        return try #require(bar.items.first { $0.title == Strings.menuEdit }?.submenu)
    }

    private func item(in menu: NSMenu, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        menu.items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
    }

    @Test func commandShiftVRunsPasteAndMatchStyleOnTheFocusedInput() throws {
        let menu = try editMenu()
        let plain = try #require(item(in: menu, key: "v", modifiers: [.command, .shift]))
        #expect(plain.title == Strings.menuPasteAndMatchStyle)
        let probe = Probe()
        let action = try #require(plain.action)
        #expect(NSApp.sendAction(action, to: probe, from: plain))
        #expect(probe.runs == ["plain"])
    }

    @Test func commandVStaysPaste() throws {
        let menu = try editMenu()
        let paste = try #require(item(in: menu, key: "v", modifiers: [.command]))
        let probe = Probe()
        #expect(NSApp.sendAction(try #require(paste.action), to: probe, from: paste))
        #expect(probe.runs == ["paste"])
    }

    /// #27619: Cmd-Shift-V in a Chromium page. The item's nil-targeted action finds no
    /// AppKit target there; the app's paste route sends Chrome's selector to the page view,
    /// with the item enabled (it did nothing before: no target, a disabled item).
    @Test func commandShiftVPastesAndMatchesStyleInAChromiumPage() throws {
        let menu = try editMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let page = ChromiumPageProbe()
        window.contentView = page
        #expect(window.makeFirstResponder(page))
        let registry = ActionRegistry.standard()
        let router = KeyRouter(registry: registry) // the router holds its registry unowned
        defer { withExtendedLifetime(registry) {} }
        for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.command, .shift, .option]] {
            let plain = try #require(item(in: menu, key: "v", modifiers: modifiers))
            let action = try #require(plain.action)
            let target = try #require(router.pasteTarget(for: action, found: nil, in: window))
            #expect((target as? any NSMenuItemValidation)?.validateMenuItem(plain) == true)
            #expect(NSApp.sendAction(action, to: target, from: plain))
        }
        #expect(page.runs == ["matchStyle", "matchStyle"])
        // A responder that answers AppKit's selector keeps it: the route never moves its paste.
        #expect(router.pasteTarget(for: #selector(NSTextView.pasteAsPlainText(_:)), found: Probe(), in: window) == nil)
    }

    /// The item follows the page view's own validation of Chrome's selector: disabled
    /// where Chrome disables Paste and Match Style.
    @Test func pasteAndMatchStyleIsDisabledWhereTheChromiumPageDisablesIt() throws {
        let menu = try editMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let page = ReadOnlyChromiumPageProbe()
        window.contentView = page
        #expect(window.makeFirstResponder(page))
        let plain = try #require(item(in: menu, key: "v", modifiers: [.command, .shift]))
        let registry = ActionRegistry.standard()
        let router = KeyRouter(registry: registry) // the router holds its registry unowned
        defer { withExtendedLifetime(registry) {} }
        let action = try #require(plain.action)
        let target = try #require(router.pasteTarget(for: action, found: nil, in: window))
        #expect((target as? any NSMenuItemValidation)?.validateMenuItem(plain) == false)
    }

    @Test func pasteAndMatchStyleSitsRightBelowPaste() throws {
        let menu = try editMenu()
        let paste = try #require(item(in: menu, key: "v", modifiers: [.command]))
        let plain = try #require(item(in: menu, key: "v", modifiers: [.command, .shift]))
        #expect(menu.index(of: plain) == menu.index(of: paste) + 1)
    }
}
