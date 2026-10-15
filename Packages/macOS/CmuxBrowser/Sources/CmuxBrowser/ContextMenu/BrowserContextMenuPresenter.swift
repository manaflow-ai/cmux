public import AppKit

/// Shows a composed page context menu as a standard `NSMenu` and reports the outcome once.
///
/// Engine rows report their id through `completion`; cmux rows run `performHostAction` and
/// complete with `nil`, as does a dismissed menu. The engine asks for its menu from inside its
/// own work (a CEF message-loop pass), and a menu's tracking loop there would stall the engine
/// while the menu is open, so ``present(_:at:in:performHostAction:completion:)`` shows the menu
/// on the next main run-loop turn and returns at once.
@MainActor
public struct BrowserContextMenuPresenter {
    /// Creates a presenter.
    public init() {}

    /// Builds the menu for `entries`.
    /// - Parameters:
    ///   - entries: The composed rows.
    ///   - performHostAction: Runs a cmux row.
    ///   - chooseEngineItem: Reports a chosen engine row's id.
    /// - Returns: The menu.
    public func makeMenu(
        _ entries: [BrowserContextMenuEntry],
        performHostAction: @escaping (BrowserContextMenuHostAction) -> Void,
        chooseEngineItem: @escaping (Int) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .engine(let item):
                menu.addItem(engineItem(item, choose: chooseEngineItem))
            case .host(let action):
                menu.addItem(hostItem(action, perform: performHostAction))
            }
        }
        return menu
    }

    /// Shows `entries` at `location` in `view` on the next run-loop turn.
    /// - Parameters:
    ///   - entries: The composed rows.
    ///   - location: The click point in `view`, top-left origin (Chromium's coordinates).
    ///   - view: The page view.
    ///   - performHostAction: Runs a cmux row.
    ///   - completion: Called exactly once: a chosen engine row's id, or `nil`.
    public func present(
        _ entries: [BrowserContextMenuEntry],
        at location: CGPoint,
        in view: NSView,
        performHostAction: @escaping (BrowserContextMenuHostAction) -> Void,
        completion: @escaping (Int?) -> Void
    ) {
        // A background page's view is in no window; AppKit cannot anchor a menu there.
        guard view.window != nil, !entries.isEmpty else { return completion(nil) }
        let once = BrowserContextMenuCompletion(completion)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak view] in
            MainActor.assumeIsolated { // main-proof: a CFRunLoopGetMain() block runs on the main thread
                guard let view, view.window != nil else { return once.finish(nil) }
                let menu = makeMenu(entries, performHostAction: { action in
                    once.finish(nil)
                    performHostAction(action)
                }, chooseEngineItem: { id in
                    once.finish(id)
                })
                let point = view.isFlipped ? location : CGPoint(x: location.x, y: view.bounds.height - location.y)
                menu.popUp(positioning: nil, at: point, in: view)
                once.finish(nil)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func engineItem(_ model: BrowserContextMenuItem, choose: @escaping (Int) -> Void) -> NSMenuItem {
        if model.kind == .separator { return .separator() }
        if model.kind == .submenu {
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: model.title)
            submenu.autoenablesItems = false
            for child in model.children { submenu.addItem(engineItem(child, choose: choose)) }
            item.submenu = submenu
            item.isEnabled = model.isEnabled
            return item
        }
        let id = model.id
        let item = BrowserMenuActionTarget.item(title: model.title) { choose(id) }
        item.isEnabled = model.isEnabled
        item.state = (model.kind == .check || model.kind == .radio) && model.isChecked ? .on : .off
        return item
    }

    private func hostItem(_ action: BrowserContextMenuHostAction, perform: @escaping (BrowserContextMenuHostAction) -> Void) -> NSMenuItem {
        let item = BrowserMenuActionTarget.item(title: Self.title(for: action)) { perform(action) }
        switch action {
        case .screenshotPage:
            item.image = NSImage(systemSymbolName: "camera", accessibilityDescription: item.title)
        case .screenshotSection:
            item.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: item.title)
        case .toggleFocusMode(let isActive):
            item.state = isActive ? .on : .off
        case .openLinkInDefaultBrowser, .moveTabToNewWorkspace:
            break
        }
        return item
    }

    /// The row title for a cmux action: the same strings the WebKit menu uses.
    /// - Parameter action: The action.
    /// - Returns: The localized title.
    public static func title(for action: BrowserContextMenuHostAction) -> String {
        switch action {
        case .openLinkInDefaultBrowser:
            String(localized: "browser.contextMenu.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser")
        case .screenshotPage:
            String(localized: "browser.contextMenu.screenshotPage", defaultValue: "Screenshot Page")
        case .screenshotSection:
            String(localized: "browser.contextMenu.screenshotSection", defaultValue: "Screenshot Section")
        case .moveTabToNewWorkspace:
            String(localized: "browser.contextMenu.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace")
        case .toggleFocusMode(let isActive):
            isActive
                ? String(localized: "browser.focusMode.context.exit", defaultValue: "Exit Browser Focus Mode")
                : String(localized: "browser.focusMode.context.enter", defaultValue: "Enter Browser Focus Mode")
        }
    }
}
