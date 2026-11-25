#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// A synthetic pointer for debug and bench builds (`debug.pointer_hover`, `debug.pointer_sweep`, cx-tupd): it
/// moves to a window point (bottom-left origin) and delivers real `mouseEntered` / `mouseMoved` / `mouseExited`
/// to every tracking area in the window whose rect contains or stops containing the point, so any hover-driven
/// view (title bar reveal, sidebar rows, section headers) reacts as it would to the real pointer. AppKit sends
/// no tracking events for a pointer that does not move, so a headless host cannot hover any other way. A nil
/// point exits every area the synthetic pointer is in.
///
/// Only the synthetic pointer's own state is tracked (with the window's synthesized pointer, `PointerHover`):
/// a real pointer move in the same window still reaches AppKit's own tracking.
///
/// ```swift
/// let report = SyntheticPointer(window: window).move(to: CGPoint(x: 120, y: 600))
/// ```
@MainActor
public final class SyntheticPointer {
    /// What one move delivered: the owners (class names) entered, exited and still inside, and how many got a
    /// `mouseMoved`.
    public struct Move: Sendable {
        public var entered: [String] = []
        public var exited: [String] = []
        public var inside: [String] = []
        public var moved = 0
    }

    /// The window the pointer moves in.
    public let window: NSWindow

    public init(window: NSWindow) {
        self.window = window
    }

    /// Moves the pointer to `point` (nil: out of every area) and delivers the events. `areas`: the window's hover
    /// areas from ``areas()``; nil walks the window's views now (one walk per move).
    public func move(to point: CGPoint?, areas given: [(NSView, NSTrackingArea)]? = nil) -> Move {
        let before = PointerHover.debugInside(in: window)
        var now: [ObjectIdentifier: NSTrackingArea] = [:]
        // Areas still attached to a view: an exit goes only to these (a removed
        // area's owner may be gone; its view re-reads the pointer itself).
        var attached: Set<ObjectIdentifier> = []
        let all = given ?? areas()
        for (view, area) in all {
            attached.insert(ObjectIdentifier(area))
            guard let point, view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
            // A tracking area's rect is in the coordinates of the view that holds it;
            // an .inVisibleRect area (rect often .zero) follows the view's visible rect,
            // as AppKit does (the sidebar list's hover, cx-qno.17).
            let local = view.convert(point, from: nil)
            let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
            if rect.contains(local) { now[ObjectIdentifier(area)] = area }
        }
        // Hover that reads where the pointer is (chrome hovers, a shown tooltip's recheck) reads
        // the synthetic pointer too, until the real mouse moves.
        PointerHover.setDebugPointer(point, inside: now, in: window)
        let location = point ?? .zero
        var report = Move()
        for (id, area) in before where now[id] == nil && attached.contains(id) {
            guard let owner = area.owner as? NSResponder, area.options.contains(.mouseEnteredAndExited),
                  let event = Self.enterExit(.mouseExited, location, window) else { continue }
            owner.mouseExited(with: event)
            report.exited.append(Self.name(owner))
        }
        for (id, area) in now {
            guard let owner = area.owner as? NSResponder else { continue }
            if before[id] == nil, area.options.contains(.mouseEnteredAndExited),
               let event = Self.enterExit(.mouseEntered, location, window) {
                owner.mouseEntered(with: event)
                report.entered.append(Self.name(owner))
            }
            if area.options.contains(.mouseMoved), let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ) {
                owner.mouseMoved(with: event)
                report.moved += 1
            }
        }
        report.entered.sort()
        report.exited.sort()
        report.inside = now.values.compactMap { ($0.owner as? NSResponder).map(Self.name) }.sorted()
        return report
    }

    /// Every hover area (entered/exited or moved) in the window, with the view that holds it.
    public func areas() -> [(NSView, NSTrackingArea)] {
        var found: [(NSView, NSTrackingArea)] = []
        var pending = [window.contentView?.superview ?? window.contentView].compactMap(\.self)
        while let next = pending.popLast() {
            for area in next.trackingAreas where area.options.contains(.mouseEnteredAndExited) || area.options.contains(.mouseMoved) {
                found.append((next, area))
            }
            pending.append(contentsOf: next.subviews)
        }
        return found
    }

    private static func enterExit(_ type: NSEvent.EventType, _ location: CGPoint, _ window: NSWindow) -> NSEvent? {
        NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
    }

    private static func name(_ owner: NSResponder) -> String { String(describing: type(of: owner)) }
}
#endif
