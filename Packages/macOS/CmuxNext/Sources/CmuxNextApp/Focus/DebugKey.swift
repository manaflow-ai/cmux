#if DEBUG
import AppKit
import CmuxNextSettings
import CmuxNextBridge
import CmuxNextBrowser

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
        "pageup": (String(UnicodeScalar(NSPageUpFunctionKey)!), 116), "pagedown": (String(UnicodeScalar(NSPageDownFunctionKey)!), 121),
        "home": (String(UnicodeScalar(NSHomeFunctionKey)!), 115), "end": (String(UnicodeScalar(NSEndFunctionKey)!), 119),
        "delete": ("\u{7f}", 51), "forwarddelete": (String(UnicodeScalar(NSDeleteFunctionKey)!), 117), "a": ("a", 0), "n": ("n", 45), "b": ("b", 11),
    ]

    /// ANSI virtual key codes, so Chromium accelerators (extension commands
    /// such as Option-Shift-U), which match on the key code, see real keys.
    private static let ansiKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, " ": 49,
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
        } else if params["target"]?.stringValue == "palette" {
            guard let panel = services.palette.visiblePanel else { return .object(["error": .string("the palette is not open")]) }
            window = panel
        } else if params["target"]?.stringValue == "debugSettings" {
            guard let debugWindow = services.debugSettings.window, debugWindow.isVisible else {
                return .object(["error": .string("Debug Settings is not open")])
            }
            window = debugWindow
        } else if params["target"]?.stringValue == "devtools" {
            let pane = params["pane"]?.stringValue ?? controller.focus.state.pane
            guard let pane, let devTools = devToolsWindow(of: pane, in: controller) else {
                return .object(["error": .string("no docked DevTools window for pane")])
            }
            window = devTools
        }
        let name = params["key"]?.stringValue ?? ""
        let key = named[name.lowercased()] ?? (name, ansiKeyCodes[name.lowercased()] ?? 0)
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
        if [115, 116, 117, 119, 121].contains(key.keyCode) { flags.insert(.function) }
        // AppKit delivers Shift-Tab as back-tab (U+0019), as a real key does.
        let characters = key.keyCode == 48 && flags.contains(.shift) ? "\u{19}" : key.characters
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key.keyCode)
        else { return .object(["error": .string("bad key")]) }
        let registry = services.registry
        let previous = registry.isDispatchingKeyDown
        registry.isDispatchingKeyDown = { true }
        defer { registry.isDispatchingKeyDown = previous }
        // The target window is the key window for this dispatch, so rules
        // that read the key window (WindowKeyTable) see it.
        let previousKey = services.keyWindowSource
        services.keyWindowSource = { [window] in window }
        defer { services.keyWindowSource = previousKey }
        let isChord = !flags.isDisjoint(with: [.command, .control])
        var trace: [String] = []
        // The dispatcher's verdict, menu gate answers and host actions this key caused.
        services.keyRouter.trace = { trace.append($0) }
        defer { services.keyRouter.trace = nil }
        // As in AppKit's dispatch, the menu gate sees this key as the current event.
        let (handledBy, action) = services.keyRouter.dispatchingSynthetic(event) { () -> (String, JSONValue) in
            if services.keyRouter.interceptKeyDown(event, in: window) {
                return ("app", services.keyRouter.lastInterception.map { .string($0.action.rawValue) } ?? .null)
            } else if isChord, window.performKeyEquivalent(with: event) {
                return (window === shell ? "window" : params["target"]?.stringValue == "devtools" ? "devtools" : "page", .null)
            } else if isChord, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return ("menu", NSApp.mainMenu.flatMap { menuItem(matching: event, in: $0) }.map { .string($0.title) } ?? .null)
            }
            window.sendEvent(event)
            return (window !== shell ? "page" : "responder", .null)
        }
        if params["target"]?.stringValue == "palette" {
            // The palette's own report: open or closed, its page, a refusal
            // notice, and key-downs that reached the system beep.
            let palette = services.palette!
            return .object([
                "handled_by": .string(handledBy == "page" ? "palette" : handledBy), "action": action, "window_kind": .string("palette"),
                "palette_open": .bool(palette.isVisible), "palette_page": .string(palette.model.pageTitle),
                "palette_text_input": .bool(palette.model.isTextInput),
                "palette_notice": palette.model.notice.map { .string($0.text) } ?? .null,
                "palette_unhandled_key_downs": .number(Double(palette.unhandledKeyDowns)),
                "palette_selected": palette.model.selectedItem.map { .string($0.actionID?.rawValue ?? $0.id) } ?? .null,
                // The row id Return runs and the first rows, so a probe tells an action row from a
                // scope or setting row with the same action.
                "palette_selected_row": palette.model.selectedItem.map { .string($0.id) } ?? .null,
                "palette_rows": .array(palette.model.rows.prefix(6).map { .string($0.id) }),
                "palette_recorder": palette.model.shortcutRecorder.map { recorder in
                    .object(["action": .string(recorder.actionID.rawValue), "message": recorder.message.map(JSONValue.string) ?? .null,
                             "recorded": recorder.recorded.map { .string($0.displayString) } ?? .null,
                             "pending": .bool(recorder.pending != nil), "options": .array(recorder.options.map { .string("\($0)") })])
                } ?? .null,
            ])
        }
        if params["target"]?.stringValue == "debugSettings" {
            return .object(["handled_by": .string(handledBy == "page" ? "debugSettings" : handledBy), "action": action,
                            "window_kind": .string("debugSettings"), "debug_settings": DebugTunables.state(services)])
        }
        let kind = window === shell ? "shell" : params["target"]?.stringValue == "devtools" ? "chromium_devtools" : "chromium_page"
        return .object(["handled_by": .string(handledBy), "action": action, "window_kind": .string(kind),
                        "trace": .array(trace.map(JSONValue.string))])
    }

    /// The first enabled main-menu item with `event`'s key equivalent (what
    /// `performKeyEquivalent` just ran), for the report.
    private static func menuItem(matching event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        for item in menu.items {
            if let submenu = item.submenu, let found = menuItem(matching: event, in: submenu) { return found }
            if item.isEnabled, !item.keyEquivalent.isEmpty, item.keyEquivalent == event.charactersIgnoringModifiers,
               item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == flags { return item }
        }
        return nil
    }

    /// The docked DevTools window of `pane`'s selected Chromium tab.
    private static func devToolsWindow(of pane: String, in controller: WindowController) -> NSWindow? {
        guard let window = controller.window, let paneController = controller.content?.paneController(key: pane),
              case .browser(let entry)? = paneController.currentContent,
              let devTools = entry.tab as? any BrowserDevToolsHosting else { return nil }
        return WindowOverlayLayer.contentChildWindows(of: window).first { devTools.devToolsContains(window: $0) }
    }

    /// The Chromium page window over `pane`'s selected Chromium tab.
    private static func pageWindow(of pane: String, in controller: WindowController) -> NSWindow? {
        guard let window = controller.window, let paneController = controller.content?.paneController(key: pane),
              case .browser(let entry)? = paneController.currentContent, entry.tab.presentation == .childWindow else { return nil }
        let content = entry.tab.contentView
        guard content.window === window else { return nil }
        let frame = window.convertToScreen(content.convert(content.bounds, to: nil))
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let devTools = entry.tab as? any BrowserDevToolsHosting
        return WindowOverlayLayer.contentChildWindows(of: window).last { child in
            child.frame.contains(center) && devTools?.devToolsContains(window: child) != true
        }
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
