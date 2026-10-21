import AppKit
import CmuxNextActions
import Foundation
import Testing

/// Ghostty's macOS default split keys stay Ghostty's in cmux-next
/// (`schemas/keybindings/ghostty-reserved-keys.json`). Lawrence 2026-10-20: "Command+Option+Arrow
/// key needs to be the original shortcut, which is the ghostty one, which is to navigate between
/// panes. [...] We need to ensure this never happens again." 2f3e1f95983 (#19788) had moved
/// Cmd-Opt-Left / Right to the sidebar's previous / next item.
///
/// The shipped binding table (``ActionRegistry/standard()``, no user files) resolves every
/// reserved key to its Ghostty action in every pane focus, and no other default entry can win
/// one there.
@MainActor @Suite struct GhosttyReservedKeysTests {
    struct Reserved: Sendable, CustomTestStringConvertible {
        let key: String
        let command: String
        var testDescription: String { "\(key) = \(command)" }
    }

    struct Context: Sendable {
        let name: String
        let values: [String: KeyContextValue]
    }

    /// `schemas/keybindings/ghostty-reserved-keys.json`, read fresh (JSON objects are not `Sendable`).
    nonisolated static func file() -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let url = root.appending(path: "schemas/keybindings/ghostty-reserved-keys.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    nonisolated static let reserved: [Reserved] = (file()["reserved"] as? [[String: Any]] ?? []).compactMap { row in
        guard let key = row["key"] as? String, let command = row["command"] as? String else { return nil }
        return Reserved(key: key, command: command)
    }

    nonisolated static let contexts: [Context] = (file()["contexts"] as? [[String: Any]] ?? []).compactMap { row in
        guard let name = row["name"] as? String, let values = row["values"] as? [String: Any] else { return nil }
        return Context(name: name, values: values.compactMapValues { any in
            if let flag = any as? Bool, CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID() { return .bool(flag) }
            if let number = any as? Double { return .number(number) }
            return (any as? String).map(KeyContextValue.string)
        })
    }

    /// A keybindings.json stroke (`cmd+opt+left`) as a ``Shortcut``.
    static func shortcut(_ text: String) throws -> Shortcut {
        var modifiers: NSEvent.ModifierFlags = []
        var key: String?
        for token in text.lowercased().split(separator: "+").map(String.init) {
            switch token {
            case "cmd": modifiers.insert(.command)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            case "left": key = Shortcut.leftArrowKey
            case "right": key = Shortcut.rightArrowKey
            case "up": key = Shortcut.upArrowKey
            case "down": key = Shortcut.downArrowKey
            case "enter": key = Shortcut.returnKey
            default: key = token
            }
        }
        return Shortcut(try #require(key, "no key in \(text)"), modifiers: modifiers)
    }

    @Test func theReservedListIsReadable() {
        #expect(Self.reserved.count >= 11)
        #expect(Self.contexts.count >= 6)
        #expect(Self.reserved.contains { $0.key == "cmd+opt+left" && $0.command == "focusLeft" })
        #expect(Self.reserved.contains { $0.key == "cmd+opt+right" && $0.command == "focusRight" })
    }

    /// Every reserved key runs its Ghostty action in a terminal, a web page, an agent chat, the
    /// Markdown and diff viewers, Home, an empty pane and the sidebar.
    @Test(arguments: reserved)
    func aReservedKeyRunsItsGhosttyActionInEveryPane(_ reserved: Reserved) throws {
        let table = RegistryKeyBindings(ActionRegistry.standard()).table
        let keys = [try Self.shortcut(reserved.key)]
        for context in Self.contexts {
            let winner = table.resolve(keys, in: KeyContext(context.values), isRunnable: { _ in true }).winner
            #expect(winner?.command.rawValue == reserved.command,
                    "\(reserved.key) in \(context.name) runs \(winner?.command.rawValue ?? "nothing"), not Ghostty's \(reserved.command)")
        }
    }

    /// No default entry on a reserved key names another action unless a `when` keeps it out of
    /// every pane focus (an editor or text field that uses the key, such as Monaco or the palette).
    @Test func noOtherDefaultClaimsAReservedKey() throws {
        let table = RegistryKeyBindings(ActionRegistry.standard()).table
        var conflicts: [String] = []
        for reserved in Self.reserved {
            let keys = [try Self.shortcut(reserved.key)]
            for entry in table.entries where entry.keys == keys && entry.command.rawValue != reserved.command {
                let leaks = Self.contexts.filter { entry.applies(in: KeyContext($0.values)) }.map(\.name)
                if entry.when == nil || !leaks.isEmpty {
                    conflicts.append("\(reserved.key): \(entry.command.rawValue) (when \(entry.when?.text ?? "none"); in \(leaks.joined(separator: ", ")))")
                }
            }
        }
        #expect(conflicts.isEmpty, "Ghostty-default keys taken by other actions: \(conflicts)")
    }

    /// The four Cmd-Opt arrows are the pane focus actions' own catalog keys, so the Keyboard
    /// Shortcuts page, the menus and the palette show them.
    @Test func theCmdOptArrowsAreThePaneFocusCatalogKeys() {
        let registry = ActionRegistry.standard()
        #expect(registry.descriptor(for: "focusLeft")?.defaultShortcut == Shortcut(Shortcut.leftArrowKey, modifiers: [.command, .option]))
        #expect(registry.descriptor(for: "focusRight")?.defaultShortcut == Shortcut(Shortcut.rightArrowKey, modifiers: [.command, .option]))
        #expect(registry.descriptor(for: "focusUp")?.defaultShortcut == Shortcut(Shortcut.upArrowKey, modifiers: [.command, .option]))
        #expect(registry.descriptor(for: "focusDown")?.defaultShortcut == Shortcut(Shortcut.downArrowKey, modifiers: [.command, .option]))
    }
}
