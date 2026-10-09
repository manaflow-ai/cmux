#if DEBUG
import AppKit
import CmuxNextSettings

/// `debug.sidebar_wheel`: scroll events at a point over a main window,
/// dispatched the way the window server hands them to the app (the window's
/// `sendEvent`, then its hit test and `scrollWheel`), so a proof can page the
/// sidebar's spaces with a mouse wheel or a trackpad gesture without
/// fronting the app or moving the pointer. Events posted to a background
/// app from outside never reach it.
///
/// Params: `x`, `y` (window points from the top left), `dy`, `dx` (lines for
/// a wheel, points per event for a trackpad), `count` (events, default 1),
/// `trackpad` (one gesture: began, changed..., ended), `window`.
/// Each event carries the time it is posted, like the window server's, so
/// a wheel's paging interval holds as it does for a real wheel.
@MainActor enum DebugSidebarWheel {
    static func post(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let window = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID })?.window else {
            return .object(["error": .string("no window")])
        }
        let point = NSPoint(x: params["x"]?.doubleValue ?? 100, y: window.frame.height - (params["y"]?.doubleValue ?? 300))
        let screen = window.convertPoint(toScreen: point)
        let location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        let dy = Int32(params["dy"]?.intValue ?? 0), dx = Int32(params["dx"]?.intValue ?? 0)
        let count = max(1, params["count"]?.intValue ?? 1)
        let trackpad = params["trackpad"]?.boolValue ?? false
        var sent = 0
        var routes: Set<String> = []
        let hit = window.contentView.flatMap { $0.hitTest($0.superview?.convert(point, from: nil) ?? point) }
        for index in 0..<count {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: trackpad ? .pixel : .line,
                                      wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { continue }
            event.location = location
            event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if trackpad {
                // kCGScrollPhaseBegan 1, Changed 2, Ended 4.
                let phase: Int64 = index == 0 ? 1 : (index == count - 1 && count > 1 ? 4 : 2)
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            }
            guard let nsEvent = NSEvent(cgEvent: event) else { continue }
            // The window's own dispatch when the event names it; otherwise the
            // view under the point, as that dispatch would pick.
            if nsEvent.window === window {
                window.sendEvent(nsEvent)
                routes.insert("window")
            } else if let hit {
                hit.scrollWheel(with: nsEvent)
                routes.insert("hit")
            } else { continue }
            sent += 1
        }
        return .object([
            "sent": .number(Double(sent)), "routes": .array(routes.sorted().map(JSONValue.string)),
            "hit": hit.map { .string(String(describing: type(of: $0))) } ?? .null,
        ])
    }
}
#endif
