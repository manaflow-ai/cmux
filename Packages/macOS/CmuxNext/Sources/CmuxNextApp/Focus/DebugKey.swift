#if DEBUG
import AppKit
import CmuxNextSettings
import CmuxNextBridge

/// `debug.key` (DEBUG builds): a key-down synthesized into one of this
/// process's own windows and dispatched the way `NSApplication.sendEvent`
/// does for the key window: the app-wide interceptor (`KeyRouter`, tiers 0
/// and 1), then window key equivalents (tier 2), then the main menu (gated
/// by the router), then the window's responder chain. With
/// `"target": "page"` the key goes to the Chromium page window of `pane`
/// (default: the focused pane), as when that page window is key.
/// Lets automation verify key routing and focus on a window that is never
/// key (`CMUX_NEXT_NO_ACTIVATE=1`). Never touches another app.
enum DebugKey {
    private static let named: [String: (characters: String, keyCode: UInt16)] = [
        "return": ("\r", 36), "escape": ("\u{1b}", 53), "tab": ("\t", 48), "d": ("d", 2), "c": ("c", 8), "v": ("v", 9),
        "l": ("l", 37), "w": ("w", 13), "t": ("t", 17), "h": ("h", 4), "j": ("j", 38), "k": ("k", 40),
        "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
        "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
    ]

    static func send(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let shell = controller.window else { return .object(["error": .string("no window")]) }
        var window: NSWindow = shell
        if params["target"]?.stringValue == "page" {
            let pane = params["pane"]?.stringValue ?? controller.focus.state.pane
            guard let pane, let page = pageWindow(of: pane, in: controller) else {
                return .object(["error": .string("no Chromium page window for pane")])
            }
            window = page
        }
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
        if key.keyCode >= 123 && key.keyCode <= 126 { flags.formUnion([.numericPad, .function]) }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                           charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode)
        else { return .object(["error": .string("bad key")]) }
        let registry = services.registry
        let previous = registry.isDispatchingKeyDown
        registry.isDispatchingKeyDown = { true }
        defer { registry.isDispatchingKeyDown = previous }
        var handledBy = "responder"
        var action: JSONValue = .null
        let isChord = !flags.isDisjoint(with: [.command, .control])
        if services.keyRouter.interceptKeyDown(event, in: window) {
            handledBy = "app"
            action = services.keyRouter.lastInterception.map { .string($0.action.rawValue) } ?? .null
        } else if isChord, window.performKeyEquivalent(with: event) {
            handledBy = window === shell ? "window" : "page"
        } else if isChord, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            handledBy = "menu"
        } else {
            window.sendEvent(event)
            if window !== shell { handledBy = "page" }
        }
        return .object(["handled_by": .string(handledBy), "action": action,
                        "window_kind": .string(window === shell ? "shell" : "chromium_page")])
    }

    /// The Chromium page window over `pane`'s selected Chromium tab.
    private static func pageWindow(of pane: String, in controller: WindowController) -> NSWindow? {
        guard let window = controller.window, let paneController = controller.content?.paneController(key: pane),
              case .browser(let entry)? = paneController.currentContent, entry.tab.presentation == .childWindow else { return nil }
        let content = entry.tab.contentView
        guard content.window === window else { return nil }
        let frame = window.convertToScreen(content.convert(content.bounds, to: nil))
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return WindowOverlayLayer.contentChildWindows(of: window).last { $0.frame.contains(center) }
    }

    /// `debug.sidebar_rename`: begins the inline rename of the window's
    /// workspace, as a double-click on its row does (the palette asks for a
    /// name instead when `renameWorkspace` runs without one).
    static func beginSidebarRename(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let workspace = controller.state.workspaceID else { return .object(["error": .string("no window")]) }
        controller.sidebar.container.beginRename(workspace: SidebarWorkspaceID(workspace))
        return .object(["workspace": .string(workspace)])
    }
}
#endif
