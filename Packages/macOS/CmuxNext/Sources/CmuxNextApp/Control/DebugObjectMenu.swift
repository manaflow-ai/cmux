#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextTabs

/// `debug.object_menu {menu, folders?, choose?, window?}` (DEBUG builds, captures of the workspace, tab and pane
/// right-click menus: `tour:object-menu-copy`). Opens the menu a person's right-click opens, then, in a later
/// call, its folders, so a change to those menus can show a before and after.
/// - `menu: "workspace"`: a right-click on the shown workspace's sidebar row (`debug.mouse`'s `row`), the
///   sidebar's own menu (`SidebarContextMenus`).
/// - `menu: "tab"`: the focused pane's selected tab's menu (`PaneController.contextMenu(for: .tab)`), opened
///   over the middle of the pane's tab strip.
/// - `menu: "pane"`: the pane's menu, the one the tab strip's empty space opens (`.emptyStrip`).
/// - `menu: "browserMore"`: the page's More menu on glass; `folders` open in place, `dismiss` closes it (no posted keys).
/// - `menu: "customizations"`: the app menu's cmux > Customizations (``CustomizationsMenu``), a fresh copy of the item
///   AppDelegate puts there with the same closures, popped over the window's top left: the menu bar is outside the
///   window a clip records (What's New `customizations-menu`). `choose: "Agent Badges"` then flips that switch
///   through its row, as a person's click does; opening it again shows the checkmark.
/// - `folders: ["More", "Copy"]`: with a menu open, opens each folder in turn with keys posted to the app's event
///   queue, which the open menu reads. A tab or pane menu (which this holds) gets Down to the folder's row, then
///   Right. The workspace menu gets a Down arrow (out of its name field), then each title typed (type-select)
///   and Right (`DebugCloudMachineFixture.folderKeys`).
/// - `choose: "Share with Guest…"` (with `folders` in the same call, or none for a top-level row): in a tab or
///   pane menu this holds, Down to that enabled row of the last folder opened, then Return, so the row runs as a
///   person's pick of it does (a run that only a person may start, such as Share with Guest's link to the
///   pasteboard).
/// - `dismiss: true`: Escape for every open level, so the menus close and the window's stills can be taken
///   (an open menu's tracking holds the main thread).
/// Answers what it opened, or `error`.
@MainActor
enum DebugObjectMenu {
    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let window = controller.window else { return failure("no window") }
        var answer: [String: JSONValue] = [:]
        if let menu = params["menu"]?.stringValue {
            switch menu {
            case "workspace":
                guard let workspace = controller.state.workspaceID else { return failure("the window shows no workspace") }
                services.debugFixtures.objectMenu = nil // a synthesized right-click opens it: its folders are typed
                answer["menu"] = DebugMouse.send(["row": .string(workspace), "button": .string("right"),
                                                  "window": .string(controller.state.id)], services: services)
            case "tab", "pane":
                guard let pane = controller.focusedPane else { return failure("the window has no focused pane") }
                let target: TabContextTarget
                if menu == "tab" {
                    guard let tab = pane.stripModel.selectedID else { return failure("the focused pane has no selected tab") }
                    target = .tab(tab, selection: [tab])
                } else {
                    target = .emptyStrip
                }
                guard let shown = pane.contextMenu(for: target) else { return failure("no \(menu) menu") }
                // Over the tab strip, else (a pane whose tab bar is hidden) the pane's top left.
                let strip: NSView = pane.view.stripView.isHidden || pane.view.stripView.window == nil ? pane.view : pane.view.stripView
                let at = strip === pane.view ? NSPoint(x: 80, y: strip.isFlipped ? 24 : strip.bounds.maxY - 24)
                    : NSPoint(x: strip.bounds.midX, y: strip.bounds.midY)
                // Later, from the main run loop: the menu's tracking runs until it closes, and this call answers
                // first. Not from a main-queue block: tracking inside one holds the main queue, so the next call
                // (`folders`, `dismiss`) would wait for the menu to close. A run-loop perform leaves the queue free,
                // as a real right-click does.
                DelayedPopUp(menu: shown, at: at, in: strip).schedule()
                services.debugFixtures.objectMenu = shown // its folders are walked by their rows
                answer["menu"] = .string(menu)
            case "browserMore":
                guard let entry = page(controller) else { return failure("the focused pane shows no browser page") }
                entry.chrome?.toolbarButtons.presentGlass(BrowserToolbarHandlers.overflowMenu(
                    for: entry, registry: services.registry, settings: services.settings), from: .overflow)
                answer["menu"] = .string(menu)
            case "browserProfile":
                // The browser toolbar's profile button menu of the focused pane's page (tour:browser-profile-menu).
                guard let pane = controller.focusedPane, case .browser(let entry) = pane.currentContent else {
                    return failure("the focused pane shows no browser page")
                }
                let shown = BrowserToolbarHandlers.profileMenu(forTab: entry.key, services: services)
                let anchor: NSView = entry.chrome ?? pane.view
                let at = NSPoint(x: anchor.bounds.maxX - 120, y: anchor.isFlipped ? 40 : anchor.bounds.maxY - 40)
                DelayedPopUp(menu: shown, at: at, in: anchor).schedule()
                services.debugFixtures.objectMenu = shown
                answer["menu"] = .string(menu)
            case "customizations":
                let item = CustomizationsMenu.item(registry: services.registry, settings: { [weak services] in services?.settings },
                                                   openAll: { [weak services] in try? services?.settingsWindow.show(section: nil, route: SettingsDeepLink.customizeRoute) })
                guard let shown = item.submenu, let content = window.contentView else { return failure("no customizations menu") }
                shown.delegate?.menuNeedsUpdate?(shown) // its rows now, so a later `choose` counts them
                // The item owns the menu's delegate (NSMenu.delegate is weak), and objectMenu is weak too.
                services.debugFixtures.customizationsItem = item
                DelayedPopUp(menu: shown, at: NSPoint(x: 96, y: content.isFlipped ? 64 : content.bounds.maxY - 64), in: content).schedule()
                services.debugFixtures.objectMenu = shown
                answer["menu"] = .string(menu)
            default:
                return failure("menu is workspace, tab, pane, browserProfile, browserMore or customizations")
            }
        }
        let folders = params["folders"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let choice = params["choose"]?.stringValue
        if let glass = page(controller)?.chrome?.toolbarButtons.shownGlassMenu {
            if params["dismiss"]?.boolValue == true { glass.close() } else if !glass.openSubmenus(folders) { return failure("no \(folders) in More") }
            return .object(answer)
        }
        if !folders.isEmpty || choice != nil {
            let events: [NSEvent]
            if let menu = services.debugFixtures.objectMenu {
                // A menu this holds: Down to each folder's row, then Right, as a person's arrow keys would.
                guard let keys = MenuArrowKeys.codes(folders, choose: choice, in: menu)?.flatMap({ arrow($0, window: window) }) else {
                    return failure("no enabled \((folders + [choice].compactMap { $0 }).joined(separator: " > ")) in the open menu")
                }
                events = keys
            } else if choice != nil {
                return failure("choose needs a tab or pane menu this opened")
            } else {
                // A Down arrow first: the workspace menu opens with its name field (MenuIdentityHeaderView) as first
                // responder, and Down hands the keys back to the menu, so the titles below type-select rows instead
                // of renaming the workspace.
                events = arrow(125, window: window) + folders.flatMap { DebugCloudMachineFixture.folderKeys($0, window: window) }
            }
            events.forEach { NSApp.postEvent($0, atStart: false) }
            answer["folderKeys"] = .number(Double(events.count))
        }
        if params["dismiss"]?.boolValue == true {
            let escapes = (0..<4).flatMap { _ in
                [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
                }
            }
            escapes.forEach { NSApp.postEvent($0, atStart: false) }
            answer["dismissKeys"] = .number(Double(escapes.count))
        }
        return .object(answer)
    }

    /// Down (125), Right (124) or Return (36), pressed and released.
    private static func arrow(_ code: UInt16, window: NSWindow) -> [NSEvent] {
        let character = code == 36 ? "\r" : FunctionKeyCharacter.string(code == 125 ? NSDownArrowFunctionKey : NSRightArrowFunctionKey)
        let flags: NSEvent.ModifierFlags = code == 36 ? [] : [.numericPad, .function]
        return [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                             characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)
        }
    }

    private static func page(_ controller: WindowController) -> BrowserEntry? {
        guard case .browser(let entry) = controller.focusedPane?.currentContent else { return nil }
        return entry
    }

    private static func failure(_ message: String) -> JSONValue { .object(["error": .string(message)]) }
}
#endif
