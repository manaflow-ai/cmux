import AppKit
import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextApp
import Testing

/// Cmd+Shift+V is Edit > Paste and Match Style (Lawrence 2026-10-20: "Command+Shift+V
/// works to paste things as just raw text in the iMessage UI"). The item sends
/// `pasteAsPlainText(_:)` down the responder chain, so every text input (the Home
/// message box, the agent chat's web composer, search fields) pastes plain text,
/// and Cmd+V stays Paste.
@MainActor @Suite struct PasteAndMatchStyleMenuTests {
    @MainActor private final class Probe: NSView {
        var runs: [String] = []
        @objc func pasteAsPlainText(_ sender: Any?) { runs.append("plain") }
        @objc func paste(_ sender: Any?) { runs.append("paste") }
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

    @Test func pasteAndMatchStyleSitsRightBelowPaste() throws {
        let menu = try editMenu()
        let paste = try #require(item(in: menu, key: "v", modifiers: [.command]))
        let plain = try #require(item(in: menu, key: "v", modifiers: [.command, .shift]))
        #expect(menu.index(of: plain) == menu.index(of: paste) + 1)
    }
}
