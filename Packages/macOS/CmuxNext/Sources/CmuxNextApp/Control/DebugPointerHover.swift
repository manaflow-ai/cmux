#if DEBUG
import AppKit
import CmuxNextSettings

/// `debug.pointer_hover` {point: [x, y] | null, window?}: moves a synthetic
/// pointer to `point` (window coordinates, bottom-left origin) in the
/// window numbered `window` (default: the active main window) and delivers
/// real `mouseEntered` / `mouseMoved` / `mouseExited` to every tracking
/// area in that window whose rect contains or stops containing the point,
/// so any hover-driven view (title bar reveal, sidebar rows, section
/// headers) reacts as it would to the real pointer. AppKit sends no
/// tracking events for a pointer that does not move, so a headless host
/// cannot hover any other way. `point` null (or absent) exits every area
/// the synthetic pointer is in. Returns the owners entered, exited and
/// still inside (their class names). Debug builds only (cx-tupd).
///
/// Only the synthetic pointer's own state is tracked: a real pointer move
/// in the same window still reaches AppKit's own tracking.
@MainActor
enum DebugPointerHover {
    /// Per window: the areas the synthetic pointer is inside.
    private static var inside: [Int: [ObjectIdentifier: NSTrackingArea]] = [:]

    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let window: NSWindow?
        if let number = params["window"]?.intValue ?? params["window"]?.stringValue.flatMap({ Int($0) }) {
            window = NSApp.windows.first { $0.windowNumber == number }
        } else {
            window = (services.windows.active ?? services.windows.controllers.first)?.window
        }
        guard let window, let root = window.contentView?.superview ?? window.contentView else {
            return .object(["error": .string("no window")])
        }
        let coords = params["point"]?.arrayValue?.compactMap(\.doubleValue)
        let point = coords.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        let key = window.windowNumber
        let before = inside[key] ?? [:]
        var now: [ObjectIdentifier: NSTrackingArea] = [:]
        // Areas still attached to a view: an exit goes only to these (a removed
        // area's owner may be gone; its view re-reads the pointer itself).
        var attached: Set<ObjectIdentifier> = []
        for (view, area) in areas(in: root) where area.options.contains(.mouseEnteredAndExited) || area.options.contains(.mouseMoved) {
            attached.insert(ObjectIdentifier(area))
            if let point {
                guard !view.isHiddenOrHasHiddenAncestor else { continue }
                // A tracking area's rect is in the coordinates of the view that holds it;
                // an .inVisibleRect area (rect often .zero) follows the view's visible rect,
                // as AppKit does (the sidebar list's hover, cx-qno.17).
                let local = view.convert(point, from: nil)
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                if rect.contains(local) { now[ObjectIdentifier(area)] = area }
            }
        }
        inside[key] = now.isEmpty ? nil : now
        let location = point ?? .zero
        var exited: [String] = []
        var entered: [String] = []
        var moved: [String] = []
        for (id, area) in before where now[id] == nil && attached.contains(id) {
            guard let owner = area.owner as? NSResponder, area.options.contains(.mouseEnteredAndExited),
                  let event = enterExit(.mouseExited, area, location, window) else { continue }
            owner.mouseExited(with: event)
            exited.append(name(owner))
        }
        for (id, area) in now {
            guard let owner = area.owner as? NSResponder else { continue }
            if before[id] == nil, area.options.contains(.mouseEnteredAndExited),
               let event = enterExit(.mouseEntered, area, location, window) {
                owner.mouseEntered(with: event)
                entered.append(name(owner))
            }
            if area.options.contains(.mouseMoved), let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ) {
                owner.mouseMoved(with: event)
                moved.append(name(owner))
            }
        }
        return .object([
            "window": .number(Double(window.windowNumber)),
            "entered": .array(entered.sorted().map(JSONValue.string)),
            "exited": .array(exited.sorted().map(JSONValue.string)),
            "inside": .array(now.values.compactMap { ($0.owner as? NSResponder).map(name) }.sorted().map(JSONValue.string)),
            "moved": .number(Double(moved.count)),
        ])
    }

    /// Every tracking area under `view`, with the view that holds it.
    private static func areas(in view: NSView) -> [(NSView, NSTrackingArea)] {
        view.trackingAreas.map { (view, $0) } + view.subviews.flatMap { areas(in: $0) }
    }

    private static func enterExit(_ type: NSEvent.EventType, _ area: NSTrackingArea, _ location: CGPoint, _ window: NSWindow) -> NSEvent? {
        NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
    }

    private static func name(_ owner: NSResponder) -> String { String(describing: type(of: owner)) }
}
#endif
