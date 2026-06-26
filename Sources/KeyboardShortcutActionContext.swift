import CmuxCommandPalette
import CmuxSettings

extension KeyboardShortcutSettings.Action {
    enum ShortcutContext: Equatable {
        case application
        case nonBrowserPanel
        case browserPanel
        case markdownPanel
        case rightSidebarFocus
        case splitPaneNavigation
        case canvasLayout
        case canvasLayoutOutsideFocusedContent

        var isAlwaysAvailable: Bool { self == .application }

        func isAvailable(
            focusedBrowserPanel: Bool,
            focusedMarkdownPanel: Bool,
            rightSidebarFocused: Bool,
            workspaceHasSplits: Bool = false,
            workspaceCanvasLayout: Bool = false
        ) -> Bool {
            switch self {
            case .application: return true
            case .nonBrowserPanel: return !focusedBrowserPanel && !rightSidebarFocused
            case .browserPanel: return focusedBrowserPanel
            case .markdownPanel: return focusedMarkdownPanel
            case .rightSidebarFocus: return rightSidebarFocused
            case .splitPaneNavigation: return workspaceHasSplits && !rightSidebarFocused
            case .canvasLayout: return workspaceCanvasLayout
            case .canvasLayoutOutsideFocusedContent: return workspaceCanvasLayout && !focusedBrowserPanel && !focusedMarkdownPanel
            }
        }

        func isAvailable(_ context: ShortcutEventFocusContext) -> Bool {
            isAvailable(
                focusedBrowserPanel: context.browserPanel != nil,
                focusedMarkdownPanel: context.markdownPanel != nil,
                rightSidebarFocused: context.rightSidebarFocused,
                workspaceHasSplits: (context.shortcutContext.int(ShortcutContextKnownKey.paneCount.rawValue) ?? 0) > 1,
                workspaceCanvasLayout: context.shortcutContext.bool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue)
            )
        }

        func isAvailable(commandPaletteContext context: CommandPaletteContextSnapshot) -> Bool {
            isAvailable(
                focusedBrowserPanel: context.bool(CommandPaletteContextKeys.panelIsBrowser),
                focusedMarkdownPanel: context.bool(CommandPaletteContextKeys.panelIsMarkdown),
                rightSidebarFocused: false,
                workspaceHasSplits: context.bool(CommandPaletteContextKeys.workspaceHasSplits),
                workspaceCanvasLayout: context.bool(CommandPaletteContextKeys.workspaceCanvasLayout)
            )
        }

        var defaultWhenClause: ShortcutWhenClause {
            switch self {
            case .application: return .always
            case .nonBrowserPanel: return .and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
            case .browserPanel: return .atom(.browserFocus)
            case .markdownPanel: return .atom(.markdownFocus)
            case .rightSidebarFocus: return .atom(.sidebarFocus)
            case .splitPaneNavigation:
                return .and(
                    .compare(key: ShortcutContextKnownKey.paneCount.rawValue, op: .greaterThan, operand: .int(1)),
                    .not(.atom(.sidebarFocus))
                )
            case .canvasLayout: return .key(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue)
            case .canvasLayoutOutsideFocusedContent:
                return .and(
                    .key(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue),
                    .and(.not(.atom(.browserFocus)), .not(.atom(.markdownFocus)))
                )
            }
        }

        func overlaps(_ other: ShortcutContext) -> Bool {
            if self == .application || other == .application || self == other {
                return true
            }
            if (self == .markdownPanel && other == .nonBrowserPanel)
                || (self == .nonBrowserPanel && other == .markdownPanel) {
                return true
            }
            if self == .canvasLayout || other == .canvasLayout {
                return true
            }
            if self == .canvasLayoutOutsideFocusedContent || other == .canvasLayoutOutsideFocusedContent {
                return self != .browserPanel && other != .browserPanel && self != .markdownPanel && other != .markdownPanel
            }
            if self == .splitPaneNavigation || other == .splitPaneNavigation {
                return self != .rightSidebarFocus && other != .rightSidebarFocus
            }
            return false
        }
    }

    var hasPriorityShortcutRouting: Bool {
        switch self {
        case .focusLeft, .focusRight:
            return true
        case .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock:
            return true
        default:
            return false
        }
    }

    var shortcutContext: ShortcutContext {
        switch self {
        case .diffViewerScrollDown, .diffViewerScrollUp, .diffViewerScrollToBottom,
             .diffViewerScrollToTop, .diffViewerOpenFileSearch:
            return .browserPanel
        case .switchRightSidebarToFiles, .switchRightSidebarToFind, .switchRightSidebarToSessions,
             .switchRightSidebarToFeed, .switchRightSidebarToDock, .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias:
            return .rightSidebarFocus
        case .renameTab, .renameWorkspace, .sendCtrlFToTerminal, .clearScreenKeepScrollback:
            return .nonBrowserPanel
        case .browserBack, .browserForward, .browserReload, .browserHardReload,
             .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole, .browserZoomIn,
             .browserZoomOut, .browserZoomReset, .toggleBrowserFocusMode:
            return .browserPanel
        case .markdownZoomIn, .markdownZoomOut, .markdownZoomReset:
            return .markdownPanel
        case .focusLeft, .focusRight:
            return .splitPaneNavigation
        case .canvasZoomReset:
            return .canvasLayoutOutsideFocusedContent
        case .canvasRevealFocusedPane, .canvasOverview, .canvasZoomIn, .canvasZoomOut,
             .canvasTidy, .canvasAlignLeft, .canvasAlignRight,
             .canvasAlignTop, .canvasAlignBottom, .canvasEqualizeWidths,
             .canvasEqualizeHeights, .canvasDistributeHorizontally, .canvasDistributeVertically:
            return .canvasLayout
        default:
            return .application
        }
    }
}
