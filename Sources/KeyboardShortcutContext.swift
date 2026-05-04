import AppKit

extension KeyboardShortcutSettings.Action {
    enum ShortcutContext: Equatable {
        case application
        case nonBrowserPanel
        case browserPanel
        case rightSidebarFocus

        func isAvailable(focusedBrowserPanel: Bool) -> Bool {
            switch self {
            case .application, .rightSidebarFocus:
                return true
            case .nonBrowserPanel:
                return !focusedBrowserPanel
            case .browserPanel:
                return focusedBrowserPanel
            }
        }

        func overlaps(_ other: ShortcutContext) -> Bool {
            if self == .rightSidebarFocus || other == .rightSidebarFocus {
                return self == other
            }
            if self == .application || other == .application {
                return true
            }
            return self == other
        }
    }

    var shortcutContext: ShortcutContext {
        switch self {
        case .switchRightSidebarToFiles, .switchRightSidebarToFind, .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock:
            return .rightSidebarFocus
        case .renameTab, .renameWorkspace:
            return .nonBrowserPanel
        case .browserBack, .browserForward, .browserReload, .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole,
             .browserZoomIn, .browserZoomOut, .browserZoomReset:
            return .browserPanel
        default:
            return .application
        }
    }
}
