import AppKit
import CmuxCanvas
import CmuxFoundation
import CmuxPanes
import CmuxSettings

extension AppDelegate {
    @discardableResult
    func performBrowserSplitShortcut(direction: SplitDirection) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else {
#if DEBUG
            cmuxDebugLog("split.browser.shortcut blocked reason=browser_disabled")
#endif
            return false
        }

        _ = synchronizeActiveMainWindowContext(preferredWindow: shortcutRoutingActiveWindow)

        if let workspace = tabManager?.selectedWorkspace, workspace.layoutMode == .canvas {
            guard let panelId = workspace.openNewCanvasPane(
                type: .browser,
                focus: true,
                direction: direction.canvasDirection
            ) else {
                return false
            }
            _ = focusBrowserAddressBar(panelId: panelId)
            return true
        }

#if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let selectedTabBefore = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.browser.shortcut pre dir=\(directionLabel) " +
            "tab=\(selectedTabBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif

        guard let panelId = tabManager?.createBrowserSplit(direction: direction) else {
#if DEBUG
            cmuxDebugLog("split.browser.shortcut failed dir=\(directionLabel)")
#endif
            return false
        }

#if DEBUG
        let selectedTabAfter = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.browser.shortcut post dir=\(directionLabel) " +
            "created=\(panelId.uuidString.prefix(5)) tab=\(selectedTabAfter) focusedPanel=\(focusedPanelAfter)"
        )
#endif

        _ = focusBrowserAddressBar(panelId: panelId)
        return true
    }

    func performToggleSplitZoomShortcut(tabManager routedManager: TabManager?) {
        if let workspace = routedManager?.selectedWorkspace, workspace.layoutMode == .canvas {
            _ = CanvasActionExecutor(workspace: workspace).perform(.toggleOverview)
        } else {
            _ = routedManager?.toggleFocusedSplitZoom()
        }
    }

    /// Matches `event` against a global zoom action, additionally accepting the
    /// shifted variants (Cmd+Shift+= types "+" on many layouts, Cmd+Shift+-
    /// types "_") while the factory default chord is bound — the same
    /// plus/minus tolerance browsers apply to their zoom shortcuts. A custom
    /// rebinding disables the tolerance and matches exactly.
    func matchGlobalZoomShortcutEvent(_ event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        if matchConfiguredShortcut(event: event, action: action) { return true }
        guard event.type == .keyDown else { return false }
        let expectedZoomAction: BrowserZoomShortcutAction
        switch action {
        case .globalZoomIn:
            expectedZoomAction = .zoomIn
        case .globalZoomOut:
            expectedZoomAction = .zoomOut
        default:
            return false
        }
        guard KeyboardShortcutSettings.shortcut(for: action) == action.defaultShortcut,
              shortcutWhenClauseAllows(action: action, event: event) else {
            return false
        }
        return browserZoomShortcutAction(
            flags: event.modifierFlags,
            chars: event.charactersIgnoringModifiers ?? "",
            keyCode: event.keyCode,
            literalChars: event.characters
        ) == expectedZoomAction
    }

    /// Steps the app-wide global font magnification from a keyboard shortcut.
    /// Shares the single mutation path with the Settings stepper and command
    /// palette: `GlobalFontMagnification` persists the percent and broadcasts
    /// `didChangeNotification`, which every terminal, browser, and chrome
    /// observer already applies live.
    @discardableResult
    func performGlobalZoomShortcut(action: KeyboardShortcutSettings.Action) -> Bool {
        let didChange: Bool
        switch action {
        case .globalZoomIn:
            didChange = GlobalFontMagnification.increasePercent()
        case .globalZoomOut:
            didChange = GlobalFontMagnification.decreasePercent()
        default:
            return false
        }
        // Consume the chord even at the 50–200% bounds so it never falls
        // through to the per-pane zooms and diverges by focus.
        if !didChange { NSSound.beep() }
        return true
    }

    func performBrowserOrTextPreviewZoomShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        let focusContext = shortcutEventFocusContext(event)
        if focusContext.filePreviewTextEditorFocused {
            let targetTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            switch action {
            case .browserZoomIn:
                return targetTabs?.zoomInFocusedTextFilePreview() ?? false
            case .browserZoomOut:
                return targetTabs?.zoomOutFocusedTextFilePreview() ?? false
            case .browserZoomReset:
                return targetTabs?.resetZoomFocusedTextFilePreview() ?? false
            default:
                return false
            }
        }

        switch action {
        case .browserZoomIn:
            return focusContext.browserPanel?.zoomIn() ?? false
        case .browserZoomOut:
            return focusContext.browserPanel?.zoomOut() ?? false
        case .browserZoomReset:
            return focusContext.browserPanel?.resetZoom() ?? false
        default:
            return false
        }
    }
}

extension SplitDirection {
    var canvasDirection: CanvasDirection {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
}
