#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextSettings
import CmuxNextTabs

/// `debug.object_menu {menu, folders?, window?}` (DEBUG builds, captures of the workspace, tab and pane
/// right-click menus: `tour:object-menu-copy`). Opens the menu a person's right-click opens, then, in a later
/// call, its folders, so a change to those menus can show a before and after.
/// - `menu: "workspace"`: a right-click on the shown workspace's sidebar row (`debug.mouse`'s `row`), the
///   sidebar's own menu (`SidebarContextMenus`).
/// - `menu: "tab"`: the focused pane's selected tab's menu (`PaneController.contextMenu(for: .tab)`), opened
///   over the middle of the pane's tab strip.
/// - `menu: "pane"`: the pane's menu, the one the tab strip's empty space opens (`.emptyStrip`).
/// - `folders: ["More", "Copy"]`: with a menu open, opens each folder in turn with keys posted to the app's event
///   queue, which the open menu reads. A tab or pane menu (which this holds) gets Down to the folder's row, then
///   Right. The workspace menu gets a Down arrow (out of its name field), then each title typed (type-select)
///   and Right (`DebugCloudMachineFixture.folderKeys`).
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
            default:
                return failure("menu is workspace, tab or pane")
            }
        }
        if let folders = params["folders"]?.arrayValue?.compactMap(\.stringValue), !folders.isEmpty {
            let events: [NSEvent]
            if let menu = services.debugFixtures.objectMenu {
                // A menu this holds: Down to each folder's row, then Right, as a person's arrow keys would.
                guard let keys = arrowKeys(folders, in: menu, window: window) else {
                    return failure("no enabled folder \(folders.joined(separator: " > ")) in the open menu")
                }
                events = keys
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

    /// The arrow keys that open `folders` in turn from `top`. Arrow keys move over enabled, shown rows (an
    /// alternate row shares its primary's place). Nothing is highlighted in a menu that just opened, so the first
    /// Down lands on its first row; a submenu opened with Right starts on its first row.
    private static func arrowKeys(_ folders: [String], in top: NSMenu, window: NSWindow) -> [NSEvent]? {
        var menu = top
        var codes: [UInt16] = []
        for (depth, title) in folders.enumerated() {
            let rows = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.isAlternate && $0.isEnabled }
            guard let index = rows.firstIndex(where: { $0.title == title }), let submenu = rows[index].submenu else { return nil }
            codes += Array(repeating: 125, count: depth == 0 ? index + 1 : index) + [124]
            menu = submenu
        }
        return codes.flatMap { arrow($0, window: window) }
    }

    /// Down (125) or Right (124), pressed and released.
    private static func arrow(_ code: UInt16, window: NSWindow) -> [NSEvent] {
        let character = FunctionKeyCharacter.string(code == 125 ? NSDownArrowFunctionKey : NSRightArrowFunctionKey)
        return [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function],
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                             characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)
        }
    }

    private static func failure(_ message: String) -> JSONValue { .object(["error": .string(message)]) }
}

/// Pops a menu up from the main run loop (`perform(_:with:afterDelay:inModes:)`), not from a main-queue block.
/// The run loop keeps it until the perform fires, once; nothing else holds it.
@MainActor
private final class DelayedPopUp: NSObject {
    private let menu: NSMenu
    private let at: NSPoint
    private weak var view: NSView?

    init(menu: NSMenu, at: NSPoint, in view: NSView) {
        self.menu = menu
        self.at = at
        self.view = view
    }

    func schedule() {
        perform(#selector(popUp), with: nil, afterDelay: 0, inModes: [.default])
    }

    @objc private func popUp() {
        guard let view, view.window != nil else { return }
        _ = menu.popUp(positioning: nil, at: at, in: view)
    }
}
#endif
