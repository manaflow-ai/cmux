#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextSettings
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextTerminal
import CmuxNextWakeups

/// `debug.key` (DEBUG builds): a key-down synthesized into one of this process's own windows and dispatched the way
/// `NSApplication.sendEvent` does for the key window: the app-wide interceptor (`KeyRouter`, tiers 0 and 1), then window
/// key equivalents (tier 2), then the main menu (gated by the router), then the window's responder chain. With no
/// `target` the key goes where a person's goes (`DebugKeyRoute`): a key child of the shell (a Chromium page with a menu
/// open), the focused chat's page when no window is key (a slot never activated), else the shell (`"target": "shell"`).
/// With `"target": "page"` it goes to the Chromium page window of `pane` (default: the focused pane), as if key.
/// Lets automation verify key routing and focus on a window that is never key (`CMUX_NEXT_NO_ACTIVATE=1`). A key the
/// responder chain gets passes the local event monitors as a real key does (DebugNativeInput), so a key in an agent pane
/// records the user's gesture. Never touches another app. A request with `sequence` plays raw key transitions through the app's
/// event queue instead, optionally into a chosen key window (`DebugKey+Sequence`); with `last`, the router's last interception.
enum DebugKey {
    private static let named: [String: (characters: String, keyCode: UInt16)] = [
        "return": ("\r", 36), "escape": ("\u{1b}", 53), "tab": ("\t", 48), "space": (" ", 49), "d": ("d", 2), "c": ("c", 8), "v": ("v", 9),
        "l": ("l", 37), "w": ("w", 13), "t": ("t", 17), "h": ("h", 4), "j": ("j", 38), "k": ("k", 40),
        "left": (Shortcut.leftArrowKey, 123), "right": (Shortcut.rightArrowKey, 124),
        "down": (Shortcut.downArrowKey, 125), "up": (Shortcut.upArrowKey, 126),
        "pageup": (FunctionKeyCharacter.string(NSPageUpFunctionKey), 116), "pagedown": (FunctionKeyCharacter.string(NSPageDownFunctionKey), 121),
        "home": (FunctionKeyCharacter.string(NSHomeFunctionKey), 115), "end": (FunctionKeyCharacter.string(NSEndFunctionKey), 119),
        "delete": ("\u{7f}", 51), "forwarddelete": (FunctionKeyCharacter.string(NSDeleteFunctionKey), 117), "a": ("a", 0), "n": ("n", 45), "b": ("b", 11),
    ]

    /// ANSI virtual key codes, so Chromium accelerators (extension commands such as Option-Shift-U), which match on the key code, see real keys.
    private static let ansiKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, " ": 49, "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, ",": 43,
        ".": 47, "/": 44, "`": 50,
    ]

    /// A shifted symbol's base key on a US keyboard (":" is Shift-";").
    private static let shiftedSymbols: [String: String] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// `debug.key`'s reply; a key a Chromium chat page that is not key gets as DevTools keys goes in after it (`devtools_keys`).
    static func reply(_ params: [String: JSONValue], services: AppServices) -> ControlReply {
        var deliver: (@Sendable () async -> Bool)?
        let answer = send(params, services: services) { deliver = $0 }
        guard let deliver, case .object(let report) = answer else { return .value(answer) }
        return .followUp { let took = await deliver(); return .object(report.merging(["devtools_keys": .bool(took)]) { $1 }) }
    }

    /// `pageKeys` takes the delivery of a key a Chromium chat page that is not key must get as DevTools key events.
    static func send(_ params: [String: JSONValue], services: AppServices, pageKeys: ((@escaping @Sendable () async -> Bool) -> Void)? = nil) -> JSONValue {
        // `last`: the action the router last took a key for (a real key's too), whether it ran, and a count that changes with every interception.
        if params["last"]?.boolValue == true {
            let router = services.keyRouter
            return .object(["count": JSONValue(router.interceptions),
                            "action": router.lastInterception.map { .string($0.action.rawValue) } ?? .null,
                            "ran": router.lastInterception.map { .bool($0.ran) } ?? .null])
        }
        let windowID = params["window"]?.stringValue
        let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID })
        // The palette opens with no main window (after Close All Windows), so its keys need none: a palette row then runs as the user's (bd cx-beg1).
        let palettePanel = params["target"]?.stringValue == "palette" && windowID == nil ? services.palette.visiblePanel : nil
        guard let shell = controller?.window ?? palettePanel else { return .object(["error": .string("no window")]) }
        let chatPage = services.registry.context.contains(.agentPaneFocused) ? controller.flatMap { c in c.focus.state.pane.flatMap { pageWindow(of: $0, in: c) } } : nil
        var window: NSWindow = DebugKeyRoute(shell: shell, keyWindow: NSApp.keyWindow, keyWindowParent: NSApp.keyWindow?.parent, focusedPage: chatPage).window(target: params["target"]?.stringValue)
        if params["target"]?.stringValue == "page" {
            let pane = params["pane"]?.stringValue ?? controller?.focus.state.pane
            guard let controller, let pane, let page = pageWindow(of: pane, in: controller) else {
                return .object(["error": .string("no Chromium page window for pane")])
            }
            window = page
        } else if params["target"]?.stringValue == "palette" {
            guard let panel = services.palette.visiblePanel else { return .object(["error": .string("the palette is not open")]) }
            window = panel
        } else if params["target"]?.stringValue == "dialog" {
            // The window holding the keyboard over the shell: an attached sheet, or the child window (a dialog overlay) whose first responder edits text.
            let editing = shell.childWindows?.first { $0.isVisible && $0.firstResponder is NSText }
            guard let dialog = shell.attachedSheet ?? editing else { return .object(["error": .string("no dialog over the window")]) }
            window = dialog
        } else if params["target"]?.stringValue == "debugSettings" {
            guard let debugWindow = services.debugSettings.window, debugWindow.isVisible else {
                return .object(["error": .string("Debug Settings is not open")])
            }
            window = debugWindow
        } else if params["target"]?.stringValue == "devtools" {
            let pane = params["pane"]?.stringValue ?? controller?.focus.state.pane
            guard let controller, let pane, let devTools = devToolsWindow(of: pane, in: controller) else {
                return .object(["error": .string("no docked DevTools window for pane")])
            }
            window = devTools
        }
        let press = keyPress(params["key"]?.stringValue ?? "", modifiers: (params["modifiers"]?.arrayValue ?? []).compactMap(\.stringValue))
        let flags = press.flags
        // `timestamp` (seconds since boot, CLOCK_UPTIME_RAW): when the client sent the key, so the typing probe
        // counts the wait for the main thread too, as a real key waits in the event queue (sidebar-churn-typing.py).
        let timestamp = params["timestamp"]?.doubleValue ?? ProcessInfo.processInfo.systemUptime
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: timestamp,
                                           windowNumber: window.windowNumber, context: nil, characters: press.characters,
                                           charactersIgnoringModifiers: press.characters, isARepeat: false, keyCode: press.keyCode)
        else { return .object(["error": .string("bad key")]) }
        // `dry_run`: what the key router would do with this key in the shell window's focus, run nothing (shortcut sweeps:
        // every app shortcut routes while a page has the keyboard). Only the router's decision: no sequences, intercepts or focus checks.
        if params["dry_run"]?.boolValue == true {
            guard let controller, window === shell else { return .object(["error": .string("dry_run needs the shell window")]) }
            let router = services.keyRouter
            let decision = router.decide(event, focus: controller.focus.state, keyWindow: .content,
                                         facts: router.facts(in: window, controller: controller))
            var action: JSONValue = .null
            if case .run(let candidate) = decision { action = .string(candidate.id.rawValue) }
            return .object(["decision": .string(String(describing: decision)), "action": action,
                            "focus": .string(String(describing: controller.focus.state.resolved))])
        }
        // The target window is the key window for this dispatch, so rules that read the key window (WindowKeyTable) see it.
        let previousKey = services.keyWindowSource
        services.keyWindowSource = { [window] in window }
        defer { services.keyWindowSource = previousKey }
        let isChord = !flags.isDisjoint(with: [.command, .control])
        var trace: [String] = []
        // The dispatcher's verdict, menu gate answers and host actions this key caused.
        services.keyRouter.trace = { trace.append($0) }
        TerminalKeyEquivalent.trace = { trace.append($0) }
        defer { services.keyRouter.trace = nil; TerminalKeyEquivalent.trace = nil }
        // The probe's sample opens before every route: `interceptKeyDown` takes a composer's key first (cmux#45273); the app's sendEvent opens its own.
        var probesKey = TypingLatencyProbe.isEnabled
        if probesKey { TypingLatencyProbe.shared.keyDown(eventTimestamp: event.timestamp) }
        // As in AppKit's dispatch, the menu gate sees this key as the current event.
        let (handledBy, action) = services.keyRouter.dispatchingSynthetic(event) { () -> (String, JSONValue) in
            if services.keyRouter.interceptKeyDown(event, in: window) {
                return ("app", services.keyRouter.lastInterception.map { verdict($0)["action"] ?? .null } ?? .null)
            } else if isChord, window.performKeyEquivalent(with: event) {
                return (window === shell ? "window" : params["target"]?.stringValue == "devtools" ? "devtools" : "page", .null)
            } else if isChord, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return ("menu", NSApp.mainMenu.flatMap { menuItem(matching: event, in: $0) }.map { .string($0.title) } ?? .null)
            }
            // As a real key: through the app and its local monitors when the window is key, else the panes' gesture monitors and then the window.
            if DebugNativeInput.usesAppKitPath(window) {
                if probesKey { TypingLatencyProbe.shared.withdraw(); probesKey = false }; DebugNativeInput.sendThroughApp([event])
            } else {
                DebugNativeInput.runPaneMonitors(event, in: window, services: services)
                // Chromium drops a key AppKit hands a page window that is not key (a slot never activated): DevTools keys reach it.
                if window !== shell, [nil, "page"].contains(params["target"]?.stringValue), let pageKeys, let controller,
                   let chat = (params["pane"]?.stringValue ?? controller.focus.state.pane).flatMap({ pageChat(of: $0, in: controller) }) {
                    let events = DebugKeyDevToolsEvents(name: params["key"]?.stringValue ?? "", modifiers: (params["modifiers"]?.arrayValue ?? []).compactMap(\.stringValue)).events.map(\.params)
                    pageKeys { await chat.debugDevToolsKeys(events) }
                } else { window.sendEvent(event) }
            }
            return (window !== shell ? "page" : "responder", .null)
        }
        if probesKey { TypingLatencyProbe.shared.mark(.dispatchEnd) }  // the first hop, whichever route took the key
        if params["probe"]?.stringValue == "commit" { TypingLatencyProbe.shared.closeAtCommit() }
        if params["target"]?.stringValue == "palette" {
            // The palette's own report: open or closed, its page, a refusal notice, and key-downs that reached the system beep.
            let palette = services.palette
            return .object([
                // With no main window the palette is the dispatch's only window.
                "handled_by": .string(handledBy == "page" || (controller == nil && ["window", "responder"].contains(handledBy)) ? "palette" : handledBy),
                "action": action, "window_kind": .string("palette"),
                "palette_open": .bool(palette.isVisible), "palette_page": .string(palette.model.pageTitle),
                "palette_text_input": .bool(palette.model.isTextInput),
                "palette_notice": palette.model.notice.map { .string($0.text) } ?? .null,
                "palette_unhandled_key_downs": .number(Double(palette.unhandledKeyDowns)),
                "palette_selected": palette.model.selectedItem.map { .string($0.actionID?.rawValue ?? $0.id) } ?? .null,
                // The row id Return runs and the first rows, so a probe tells an action row from a scope or setting row with the same action.
                "palette_selected_row": palette.model.selectedItem.map { .string($0.id) } ?? .null,
                // The rows on screen when this reply is built. A query ranks off the main actor: while `palette_ranking` is true they
                // are stand-ins (the previous query's rows), and while `palette_loading` is true a provider can still add rows and
                // rank again. Read the rows again when both are false, or use the `palette.query` socket method.
                "palette_query": .string(palette.model.query),
                "palette_ranking": .bool(palette.model.isRanking),
                "palette_loading": .bool(palette.model.isLoading),
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
        var report: [String: JSONValue] = ["handled_by": .string(handledBy), "action": action, "window_kind": .string(kind),
                                           "trace": .array(trace.map(JSONValue.string))]
        if handledBy == "app", let interception = services.keyRouter.lastInterception {
            report.merge(verdict(interception)) { _, new in new }
        }
        return .object(report)
    }

    /// The key-down `debug.key` sends for `name` (a key name such as `return`, or the character typed) and `modifiers`
    /// (`cmd`, `shift`, `option`, `control`). A typed character keeps its case (the named "d" or "l" must not turn "D" or
    /// "L" into lowercase), and a capital letter has Shift, as from a keyboard.
    static func keyPress(_ name: String, modifiers: [String]) -> (characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let lower = name.lowercased()
        let capital = name.count == 1 && name != lower && name.uppercased() == name
        let shiftedBase = shiftedSymbols[name]
        let key: (characters: String, keyCode: UInt16) =
            if capital { (name, ansiKeyCodes[lower] ?? 0) }
            else if let shiftedBase { (name, ansiKeyCodes[shiftedBase] ?? 0) }
            else { named[lower] ?? (name, ansiKeyCodes[lower] ?? 0) }
        var flags: NSEvent.ModifierFlags = capital || shiftedBase != nil ? .shift : []
        for modifier in modifiers {
            switch modifier {
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
        return (characters, key.keyCode, flags)
    }

    /// What debug.key reports for an intercepted chord: the action when it ran; a refused run names it as `refused_action`.
    static func verdict(_ interception: (action: ActionID, window: String, ran: Bool)) -> [String: JSONValue] {
        interception.ran ? ["action": .string(interception.action.rawValue)]
            : ["action": .null, "refused_action": .string(interception.action.rawValue)]
    }

    /// The first enabled main-menu item with `event`'s key equivalent (what `performKeyEquivalent` just ran), for the report.
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

    /// The content view of `pane`'s selected Chromium tab when its page is in tree (the page's view is in the cmux
    /// window, so there is no page window to click).
    static func inTreePageView(of pane: String, in controller: WindowController) -> NSView? {
        guard let window = controller.window, let paneController = controller.content?.paneController(key: pane),
              case .browser(let entry)? = paneController.currentContent, entry.tab.presentation == .inTree,
              entry.tab.contentView.window === window else { return nil }
        return entry.tab.contentView
    }

    /// The agent chat `pane` shows in Chromium, nil for any other pane.
    static func pageChat(of pane: String, in controller: WindowController) -> AgentPaneView? {
        guard let key = controller.content?.paneController(key: pane)?.currentTabKey, let chat = controller.services.agentTabs.existingView(key) else { return nil }
        return chat.engineName == "cef" ? chat : nil
    }

    /// The Chromium page window over `pane`'s selected Chromium tab, or over its agent chat when the chat shows in Chromium.
    static func pageWindow(of pane: String, in controller: WindowController) -> NSWindow? {
        guard let window = controller.window, let paneController = controller.content?.paneController(key: pane) else { return nil }
        let content: NSView
        var devTools: (any BrowserDevToolsHosting)?
        if case .browser(let entry)? = paneController.currentContent, entry.tab.presentation == .childWindow {
            content = entry.tab.contentView
            devTools = entry.tab as? any BrowserDevToolsHosting
        } else if let chat = pageChat(of: pane, in: controller) {
            content = chat
        } else {
            return nil
        }
        guard content.window === window else { return nil }
        let frame = window.convertToScreen(content.convert(content.bounds, to: nil))
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return WindowOverlayLayer.contentChildWindows(of: window).last { child in
            child.frame.contains(center) && devTools?.devToolsContains(window: child) != true
        }
    }

    /// `debug.window.focus {window, activate?}`: orders that cmux window front and makes it the app's key window, without activating the app
    /// unless `activate` (a bench's typed keys), so window actions can be proven on a chosen window. An app that is not active has no key window:
    /// the window still becomes the active one (`WindowManager.active`), so a no-activate check acts in it (#38063). Returns the key and front window ids.
    static func focusWindow(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let id = params["window"]?.stringValue, let controller = services.windows.controllers.first(where: { $0.state.id == id }),
              let window = controller.window else { return .object(["error": .string("no window with that id")]) }
        if params["activate"]?.boolValue == true { NSApp.activate() }; window.orderFrontRegardless() // focus-route: debug.window.focus is an explicit focus command
        window.makeKey()
        if !window.isKeyWindow { services.windows.didActivate(controller) }
        let windowID = { (window: NSWindow?) -> JSONValue in
            services.windows.controllers.first { $0.window === window }.map { .string($0.state.id) } ?? .null
        }
        let front = NSApp.orderedWindows.first { candidate in services.windows.controllers.contains { $0.window === candidate } }
        return .object(["key": windowID(NSApp.keyWindow), "front": windowID(front)])
    }

    /// `debug.sidebar_rename`: begins the inline rename of the window's workspace, as a double-click on its row does (the
    /// palette asks for a name instead when `renameWorkspace` runs without one).
    static func beginSidebarRename(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let workspace = controller.state.workspaceID else { return .object(["error": .string("no window")]) }
        controller.sidebar.container.beginRename(workspace: SidebarWorkspaceID(workspace))
        return .object(["workspace": .string(workspace)])
    }
}
#endif
