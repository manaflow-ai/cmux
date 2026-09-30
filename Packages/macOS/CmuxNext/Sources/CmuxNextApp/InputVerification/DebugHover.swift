#if DEBUG
import AppKit

/// `debug.mouse` `hover` (DEBUG builds): hover without the user's pointer.
/// AppKit derives tracking-area events from the real cursor, not from
/// posted mouse-moved events, so this walks the window's views and sends
/// each tracking area's owner the entered, moved and exited events the
/// real pointer would cause at `point`. Only this process's own window
/// sees them.
@MainActor
enum DebugHover {
    private struct Inside {
        weak var owner: NSResponder?
    }

    /// Owners of tracking areas the simulated pointer is in, per window.
    /// Keyed by owner: views replace their areas in updateTrackingAreas.
    private static var inside: [Int: [ObjectIdentifier: Inside]] = [:]

    /// `location` is in window base coordinates. Returns the owners that
    /// received an event.
    static func move(to location: NSPoint, in window: NSWindow) -> Int {
        guard let root = window.contentView?.superview ?? window.contentView else { return 0 }
        let previous = inside[window.windowNumber] ?? [:]
        var now: [ObjectIdentifier: Inside] = [:]
        var delivered = 0
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            for area in view.trackingAreas where area.options.contains(.mouseEnteredAndExited) || area.options.contains(.mouseMoved) {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard let owner = area.owner as? NSResponder, rect.contains(view.convert(location, from: nil)) else { continue }
                let id = ObjectIdentifier(owner)
                now[id] = Inside(owner: owner)
                if previous[id] == nil, area.options.contains(.mouseEnteredAndExited), let event = crossing(.mouseEntered, location, window) {
                    owner.mouseEntered(with: event)
                    delivered += 1
                }
                if area.options.contains(.mouseMoved), let event = moved(location, window) {
                    owner.mouseMoved(with: event)
                    delivered += 1
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        for (id, entry) in previous where now[id] == nil {
            guard let owner = entry.owner, let event = crossing(.mouseExited, location, window) else { continue }
            owner.mouseExited(with: event)
            delivered += 1
        }
        inside[window.windowNumber] = now
        return delivered
    }

    private static func crossing(_ type: NSEvent.EventType, _ location: NSPoint, _ window: NSWindow) -> NSEvent? {
        NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
    }

    private static func moved(_ location: NSPoint, _ window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
    }
}
#endif
