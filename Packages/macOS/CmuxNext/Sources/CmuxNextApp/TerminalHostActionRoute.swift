import CmuxNextActions
import CmuxNextTerminal

/// Maps a Ghostty keybind request (`new_split:right`, `goto_split:left`,
/// `equalize_splits`, ...) to the registry action that the shortcut, menu,
/// palette, and CLI run, so a keybind in the user's Ghostty config takes the
/// same path as every other entrypoint. Nil means the app has no action for
/// it; Ghostty then treats the key as unbound.
enum TerminalHostActionRoute {
    struct Route: Equatable {
        var id: ActionID
        var arguments: [String: ActionValue] = [:]
    }

    static func route(_ action: TerminalHostAction) -> Route? {
        switch action {
        case .newSplit(let direction):
            return Route(id: split(direction))
        case .gotoSplit(let target):
            return Route(id: focus(target))
        case .resizeSplit(let direction, _):
            // The registry resizes by its own step; Ghostty's amount is in
            // points of its own split tree and has no daemon equivalent.
            return Route(id: resize(direction))
        case .equalizeSplits:
            return Route(id: "equalizeSplits")
        case .toggleSplitZoom:
            return Route(id: "toggleSplitZoom")
        case .newTab:
            return Route(id: "newSurface")
        case .closeTab(let mode):
            return Route(id: closeTab(mode))
        case .gotoTab(let target):
            return gotoTab(target)
        case .moveTab(let amount):
            guard amount != 0 else { return nil }
            return Route(id: amount < 0 ? "moveSurfaceLeft" : "moveSurfaceRight")
        case .newWindow:
            return Route(id: "newWindow")
        case .closeWindow:
            return Route(id: "closeWindow")
        case .toggleFullscreen:
            return Route(id: "toggleFullScreen")
        case .toggleCommandPalette:
            return Route(id: "commandPalette")
        case .promptTitle:
            return Route(id: "renameTab")
        case .find:
            return Route(id: "find")
        case .closeAllWindows, .quit, .toggleMaximize, .toggleInspector, .checkForUpdates, .undo, .redo:
            return nil
        }
    }

    private static func split(_ direction: TerminalHostAction.SplitDirection) -> ActionID {
        switch direction {
        case .right: "splitRight"
        case .down: "splitDown"
        case .left: "splitLeft"
        case .up: "splitUp"
        }
    }

    private static func focus(_ target: TerminalHostAction.SplitNavigation) -> ActionID {
        switch target {
        case .left: "focusLeft"
        case .right: "focusRight"
        case .up: "focusUp"
        case .down: "focusDown"
        case .previous: "focusPreviousPane"
        case .next: "focusNextPane"
        }
    }

    private static func resize(_ direction: TerminalHostAction.SplitDirection) -> ActionID {
        switch direction {
        case .left: "resizePaneLeft"
        case .right: "resizePaneRight"
        case .up: "resizePaneUp"
        case .down: "resizePaneDown"
        }
    }

    private static func closeTab(_ mode: TerminalHostAction.CloseTabMode) -> ActionID {
        switch mode {
        case .this: "closeTab"
        case .others: "closeOtherTabsInPane"
        case .right: "closeTabsToRight"
        }
    }

    private static func gotoTab(_ target: TerminalHostAction.TabTarget) -> Route {
        switch target {
        case .previous: Route(id: "prevSurface")
        case .next: Route(id: "nextSurface")
        // selectSurfaceByNumber treats 9 as "last".
        case .last: Route(id: "selectSurfaceByNumber", arguments: ["index": .int(9)])
        case .index(let number): Route(id: "selectSurfaceByNumber", arguments: ["index": .int(max(1, number))])
        }
    }
}
