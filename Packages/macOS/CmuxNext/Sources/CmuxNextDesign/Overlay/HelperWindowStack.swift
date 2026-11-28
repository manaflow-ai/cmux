public import AppKit

/// The one decision of which window gets a pointer event at a screen point, among a main window and the helper
/// windows over its content.
///
/// A main window has three kinds of helper windows: the overlay panel (``WindowOverlayHost``: dialogs, toasts, menus),
/// the divider catchers (``UnderOverlayWindow``: a transparent panel over each divider a Chromium page covers) and one
/// child window per Chromium page. From the top, the person sees: an overlay where one takes the mouse, then a
/// catcher, then the window itself over an occluder (the sidebar, which page frames run under), then the front page,
/// then the window. The window server picks by its own window order and by which windows take the mouse at that
/// moment (the panel switches on only after a move the app saw; the Chromium fork orders a page above every other
/// child each time it shows, until the host orders it back), so an event can reach a window that is not on top for the
/// person. Every helper that passes an event on asks this for where it goes, instead of a rule of its own: the
/// overlay's take-back of a press or scroll from below, what the panel passes on where no overlay is, and a divider
/// catcher's scroll (a127's findings on cmux#45851, 2026-11-17).
///
/// The real fix for the class is one window per main window, with pages drawn in layers of it (P7, layer-hosted
/// pages); until then this is the one owner of the order.
@MainActor
public struct HelperWindowStack {
    /// A layer of the stack, top to bottom.
    public enum Layer: Equatable {
        /// An overlay of the window's ``WindowOverlayHost`` takes the mouse here.
        case overlay
        /// A divider catcher.
        case catcher(NSWindow)
        /// A Chromium page's window.
        case page(NSWindow)
        /// The main window itself.
        case window

        var rank: Int {
            switch self {
            case .overlay: 0
            case .catcher: 1
            case .page: 2
            case .window: 3
            }
        }
    }

    /// Where an asking helper sits: the target is looked for only in the layers under it.
    public enum Asker {
        /// Nothing of the stack: every layer counts.
        case none
        /// The overlay panel: what is under the overlays.
        case overlay
        /// A divider catcher: what is under the catchers.
        case catcher

        var firstRank: Int {
            switch self {
            case .none: 0
            case .overlay: 1
            case .catcher: 2
            }
        }
    }

    /// The main window.
    public let window: NSWindow

    public init(window: NSWindow) {
        self.window = window
    }

    /// The layer that gets a pointer event at `screen` (a screen point), among the layers under `asker`.
    ///
    /// - Parameters:
    ///   - screen: The event's point in screen coordinates.
    ///   - asker: The helper that asks, whose own layer and those above it do not count.
    /// - Returns: The top layer at the point under `asker`; ``Layer/window`` when no helper is there.
    public func target(atScreen screen: NSPoint, under asker: Asker = .none) -> Layer {
        let first = asker.firstRank
        if first <= 0, WindowOverlayHost.overlayTakesMouse(in: window, atWindowPoint: window.convertPoint(fromScreen: screen)) {
            return .overlay
        }
        if first <= 1, let catcher = frontCatcher(at: screen) { return .catcher(catcher) }
        let windowPoint = window.convertPoint(fromScreen: screen)
        if let host = WindowOverlayHost.existingHost(for: window), host.occluderRects.contains(where: { $0.contains(windowPoint) }) {
            return .window
        }
        if let page = WindowOverlayHost.frontPageWindow(at: screen, in: window) { return .page(page) }
        return .window
    }

    /// The window of `layer`: the overlay panel, the catcher, the page or the main window.
    public func window(of layer: Layer) -> NSWindow {
        switch layer {
        case .overlay: WindowOverlayHost.host(for: window).panel
        case let .catcher(catcher): catcher
        case let .page(page): page
        case .window: window
        }
    }

    /// Sends `event` at `screen` to the layer under `asker` there, as the window server would have sent it to that
    /// layer's window: through the window's `sendEvent`, so the window's own routing (its overlay take-back, its divider
    /// and titlebar presses) runs as for any event. Returns the layer it went to.
    ///
    /// A scroll that cannot be addressed to the window (no event copy) goes to the view under the point in that window.
    @discardableResult
    public func deliver(_ event: NSEvent, atScreen screen: NSPoint, under asker: Asker) -> Layer {
        let layer = target(atScreen: screen, under: asker)
        let target = window(of: layer)
        if let addressed = Self.addressed(event, to: target, screen: screen) {
            target.sendEvent(addressed)
        } else if event.type == .scrollWheel, let content = target.contentView {
            let point = target.convertPoint(fromScreen: screen)
            content.hitTest(content.superview?.convert(point, from: nil) ?? point)?.scrollWheel(with: event)
        }
        return layer
    }

    /// The frontmost divider catcher of the window that takes the mouse at `screen`.
    func frontCatcher(at screen: NSPoint) -> NSWindow? {
        let catchers = (window.childWindows ?? []).filter {
            $0 is any UnderOverlayWindow && $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(screen)
        }
        guard catchers.count > 1 else { return catchers.first }
        let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
        return catchers.min { (order.firstIndex(of: $0.windowNumber) ?? .max) < (order.firstIndex(of: $1.windowNumber) ?? .max) }
    }

    /// The screen point of a pointer event: its global location, which holds wherever the event was sent (a synthesized
    /// event has no window, and a drag's pointer leaves the window that has it).
    public static func screenPoint(of event: NSEvent) -> NSPoint {
        if let location = event.cgEvent?.location, let height = NSScreen.screens.first?.frame.height {
            return NSPoint(x: location.x, y: height - location.y)
        }
        return event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    /// `event` as the window server would have sent it to `target` at `screen` (a screen point); nil for a scroll that
    /// cannot be addressed there.
    public static func addressed(_ event: NSEvent, to target: NSWindow, screen: NSPoint) -> NSEvent? {
        // A copy of the real event keeps its drag and scroll deltas (pointer lock, page drags use them); only the window
        // and location change.
        if let copy = event.cgEvent?.copy() {
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowNumber))
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowNumber))
            if let forwarded = NSEvent(cgEvent: copy) {
                let addressed = relocated(forwarded, to: target, screen: screen)
                if addressed == nil, forwarded.type == .scrollWheel { return nil }
                return addressed ?? forwarded
            }
        }
        return relocated(event, to: target, screen: screen)
    }

    /// `event` addressed to `target` at the screen point (deltas are lost: a fallback only). Nil for a scroll, which has
    /// no such constructor.
    static func relocated(_ event: NSEvent, to target: NSWindow, screen: NSPoint) -> NSEvent? {
        guard event.window !== target else { return event }
        guard event.type != .scrollWheel else { return nil }
        return NSEvent.mouseEvent(with: event.type, location: target.convertPoint(fromScreen: screen),
                                  modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                  windowNumber: target.windowNumber, context: nil, eventNumber: event.eventNumber,
                                  clickCount: event.clickCount, pressure: event.pressure)
    }
}
