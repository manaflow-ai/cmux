import AppKit

func browserPopupContentRect(
    requestedWidth: CGFloat?,
    requestedHeight: CGFloat?,
    requestedX: CGFloat?,
    requestedTopY: CGFloat?,
    visibleFrame: NSRect,
    defaultWidth: CGFloat = 800,
    defaultHeight: CGFloat = 600,
    minWidth: CGFloat = 200,
    minHeight: CGFloat = 150
) -> NSRect {
    let clampedWidth = min(max(requestedWidth ?? defaultWidth, minWidth), visibleFrame.width)
    let clampedHeight = min(max(requestedHeight ?? defaultHeight, minHeight), visibleFrame.height)

    let x: CGFloat
    let y: CGFloat
    if let requestedX, let requestedTopY {
        x = max(visibleFrame.minX, min(requestedX, visibleFrame.maxX - clampedWidth))

        // Web content expresses popup Y as distance from the screen's top edge,
        // while AppKit window origins are bottom-up.
        let appKitY = visibleFrame.maxY - requestedTopY - clampedHeight
        y = max(visibleFrame.minY, min(appKitY, visibleFrame.maxY - clampedHeight))
    } else {
        x = visibleFrame.midX - clampedWidth / 2
        y = visibleFrame.midY - clampedHeight / 2
    }

    return NSRect(x: x, y: y, width: clampedWidth, height: clampedHeight)
}

private func browserPopupPanelShouldSuppressStaleCloseTabShortcut(_ event: NSEvent) -> Bool {
    let closeTabShortcut = KeyboardShortcutSettings.shortcut(for: .closeTab)
    guard closeTabShortcut.isUnbound || closeTabShortcut != KeyboardShortcutSettings.Action.closeTab.defaultShortcut else {
        return false
    }
    return KeyboardShortcutSettings.Action.closeTab.defaultShortcut.matches(event: event)
}

/// NSPanel subclass that intercepts the configured Close Tab shortcut before the swizzled
/// `cmux_performKeyEquivalent` can dispatch it to the main menu's
/// "Close Tab" action (which would close the parent browser tab).
final class BrowserPopupPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AppDelegate.shared?.handleBrowserPopupCloseShortcutKeyEquivalent(event: event, popupWindow: self) == true {
            return true
        }
        if browserPopupPanelShouldSuppressStaleCloseTabShortcut(event) {
            #if DEBUG
            cmuxDebugLog("popup.panel.closeShortcut suppressStaleDefault")
            #endif
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
