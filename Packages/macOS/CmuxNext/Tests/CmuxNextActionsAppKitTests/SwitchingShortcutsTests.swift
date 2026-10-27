import AppKit
import CmuxNextActions
import Testing

/// Home's first-run Switching card reads its keys from the live binding
/// table (`SwitchingShortcuts`), so the card follows a rebind, and checks
/// Mission Control's Switch to Desktop keys (`MissionControlDesktopKeys`).
@MainActor @Suite struct SwitchingShortcutsTests {
    @Test func defaultsShowTheDocumentedSwitchingKeys() {
        let keys = SwitchingShortcuts(registry: ActionRegistry.standard())
        #expect(keys.tabByNumber == "⌃1…9")
        #expect(keys.workspaceByNumber == "⌘1…9")
        #expect(keys.nextPreviousTab == "⇧⌘[ ⇧⌘]")
        #expect(keys.nextPreviousWorkspace == "⌃⌘[ ⌃⌘]")
        #expect(keys.focusBackForward == "⌘[ ⌘]")
        #expect(keys.tabByNumberModifiers == NSEvent.ModifierFlags.control.rawValue)
    }

    @Test func aCmuxJSONRebindShowsTheNewKey() {
        let registry = ActionRegistry.standard()
        registry.setShortcutOverride(Shortcut("1", modifiers: [.control, .option]), for: "selectSurfaceByNumber")
        registry.setShortcutOverride(Shortcut("n", modifiers: [.command, .option]), for: "nextSurface")
        let keys = SwitchingShortcuts(registry: registry)
        #expect(keys.tabByNumber == "⌃⌥1…9")
        #expect(keys.tabByNumberModifiers == NSEvent.ModifierFlags([.control, .option]).rawValue)
        #expect(keys.nextPreviousTab == "⇧⌘[ ⌥⌘N")
    }

    @Test func aKeybindingsJSONEntryWinsAndARemovalHidesTheLine() {
        let registry = ActionRegistry.standard()
        KeyBindingLoader(registry).load(KeyBindingLayers(
            user: [KeyBinding(keys: [Shortcut("j", modifiers: [.control, .option])], command: "nextSidebarTab", source: .user)],
            removals: [KeyBindingRemoval(command: "focusHistoryBack"), KeyBindingRemoval(command: "focusHistoryForward")]
        ))
        let keys = SwitchingShortcuts(registry: registry)
        #expect(keys.nextPreviousWorkspace == "⌃⌘[ ⌃⌥J")
        #expect(keys.focusBackForward == nil)
    }

    @Test func anUnboundTabFamilyHasNoKeyAndNoModifiers() {
        let registry = ActionRegistry.standard()
        registry.setShortcutOverride(nil, for: "selectSurfaceByNumber")
        let keys = SwitchingShortcuts(registry: registry)
        #expect(keys.tabByNumber == nil)
        #expect(keys.tabByNumberModifiers == nil)
    }

    @Test func missionControlDesktopKeysConflictOnlyWhenOnWithTheSameModifiers() {
        let control = NSEvent.ModifierFlags.control.rawValue
        func hotKey(_ enabled: Bool, modifiers: UInt) -> [String: Any] {
            ["enabled": enabled, "value": ["parameters": [49, 18, modifiers], "type": "standard"]]
        }
        #expect(!MissionControlDesktopKeys(symbolicHotKeys: nil).conflicts(withDigitModifiers: control))
        #expect(!MissionControlDesktopKeys(symbolicHotKeys: ["118": hotKey(false, modifiers: 262_144)]).conflicts(withDigitModifiers: control))
        let on = MissionControlDesktopKeys(symbolicHotKeys: ["118": hotKey(true, modifiers: 262_144)])
        #expect(on.conflicts(withDigitModifiers: control))
        #expect(!on.conflicts(withDigitModifiers: NSEvent.ModifierFlags([.control, .option]).rawValue))
        // Another symbolic hot key (Mission Control itself, 32) never counts.
        #expect(!MissionControlDesktopKeys(symbolicHotKeys: ["32": hotKey(true, modifiers: 262_144)]).conflicts(withDigitModifiers: control))
        // Preferences store the flag as a number too.
        #expect(MissionControlDesktopKeys(symbolicHotKeys: ["119": ["enabled": NSNumber(value: 1),
                                                                    "value": ["parameters": [50, 19, NSNumber(value: 262_144)]]]])
            .conflicts(withDigitModifiers: control))
    }
}
