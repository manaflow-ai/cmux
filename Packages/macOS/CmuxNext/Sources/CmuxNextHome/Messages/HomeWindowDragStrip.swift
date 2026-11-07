public import AppKit

/// A thin strip over the Messages page's top edge that moves the window, as the native list's
/// header did (a web view never moves its window); a double-click zooms or minimizes per the
/// person's system setting, as a title bar does.
public final class HomeWindowDragStrip: NSView {
    public static let height: CGFloat = 8

    override public var mouseDownCanMoveWindow: Bool { true }

    override public func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            return
        }
        window.performDrag(with: event)
    }
}
