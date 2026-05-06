import AppKit

@MainActor
final class CmuxMainWindow: NSWindow {
    private var isSoftHiddenForVisibilityController = false

    func setSoftHiddenForVisibilityController(_ isSoftHidden: Bool) {
        isSoftHiddenForVisibilityController = isSoftHidden
        if isSoftHidden {
            makeFirstResponder(nil)
            ignoresMouseEvents = true
            alphaValue = 0
        } else {
            alphaValue = 1
            ignoresMouseEvents = false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.flagsChanged(with: event)
    }
}

extension CmuxMainWindow {
    private static let defaultContentSize = NSSize(width: 1_000, height: 700)

    static func defaultContentRect(styleMask: NSWindow.StyleMask) -> NSRect {
        let contentRect = NSRect(origin: .zero, size: defaultContentSize)
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return contentRect
        }

        let frameRect = NSWindow.frameRect(forContentRect: contentRect, styleMask: styleMask)
        return NSWindow.contentRect(
            forFrameRect: clampedFrame(frameRect, within: visibleFrame),
            styleMask: styleMask
        )
    }

    private static func clampedFrame(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        let width = min(max(frame.width, defaultContentSize.width), visibleFrame.width)
        let height = min(max(frame.height, defaultContentSize.height), visibleFrame.height)
        return NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }
}

extension AppDelegate {
    func resolvedPersistedWindowGeometryFrame() -> NSRect? {
        let displays = currentDisplayGeometries()
        let fallbackGeometry = persistedWindowGeometry()
        return Self.resolvedWindowFrame(
            from: fallbackGeometry?.frame,
            display: fallbackGeometry?.display,
            availableDisplays: displays.available,
            fallbackDisplay: displays.fallback
        )
    }
}
