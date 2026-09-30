#if DEBUG
import AppKit
import CmuxNextSettings
import CmuxNextBridge

/// `debug.key` (DEBUG builds): a key-down synthesized into one of this
/// process's own windows and dispatched like `NSApplication.sendEvent`
/// does for the key window: window key equivalents (the `KeyRouter`), then
/// the main menu (gated by the router), then the window's responder chain.
/// Lets automation verify key routing and focus on a window that is never
/// key (`CMUX_NEXT_NO_ACTIVATE=1`). Never touches another app.
enum DebugKey {
    private static let named: [String: (characters: String, keyCode: UInt16)] = [
        "return": ("\r", 36), "escape": ("\u{1b}", 53), "tab": ("\t", 48), "d": ("d", 2), "c": ("c", 8), "v": ("v", 9),
        "l": ("l", 37), "w": ("w", 13), "t": ("t", 17),
    ]

    static func send(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let window = controller.window else { return .object(["error": .string("no window")]) }
        let name = params["key"]?.stringValue ?? ""
        let key = named[name.lowercased()] ?? (name, 0)
        var flags: NSEvent.ModifierFlags = []
        for modifier in params["modifiers"]?.arrayValue ?? [] {
            switch modifier.stringValue {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            default: break
            }
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                           charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode)
        else { return .object(["error": .string("bad key")]) }
        let registry = services.registry
        let previous = registry.isDispatchingKeyDown
        registry.isDispatchingKeyDown = { true }
        defer { registry.isDispatchingKeyDown = previous }
        var handledBy = "responder"
        if !flags.isDisjoint(with: [.command, .control]), window.performKeyEquivalent(with: event) {
            handledBy = "window"
        } else if !flags.isDisjoint(with: [.command, .control]), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            handledBy = "menu"
        } else {
            window.sendEvent(event)
        }
        return .object(["handled_by": .string(handledBy)])
    }

    /// `debug.sidebar_rename`: begins the inline rename of the window's
    /// workspace, as a double-click on its row does (the palette asks for a
    /// name instead when `renameWorkspace` runs without one).
    static func beginSidebarRename(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let workspace = controller.state.workspaceID else { return .object(["error": .string("no window")]) }
        controller.sidebar.container.sidebarView.beginRename(workspace: SidebarWorkspaceID(workspace))
        return .object(["workspace": .string(workspace)])
    }
}
#endif
