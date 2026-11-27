#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextSettings

extension DebugAgentCursor {
    /// `debug.agent_cursor.click_tag` (DEBUG builds): a click on the name tag
    /// of cursor `session` (default: the first tag a window shows), as the
    /// person's: a mouse down and up at the tag's center, sent to the window
    /// that draws the cursor (the overlay panel above the pages), so it takes
    /// that window's mouse routing, the hit test, the carrier's click and the
    /// tag's link. Answers the session and window clicked, or `error`.
    static func clickTag(_ params: [String: CmuxNextSettings.JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        let wanted = params["session"]?.stringValue
        for controller in services.windows.controllers {
            guard let window = controller.window else { continue }
            let tags = controller.agentCursorTags.agentCursorTags()
            guard let tag = tags.first(where: { wanted == nil || $0.id == wanted }),
                  let hit = WindowOverlayHost.existingHost(for: window)?.agentCursorTagClickPoint(tag.id) else { continue }
            let (target, point) = (hit.window, hit.point)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: target.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                    return .object(["error": .string("could not synthesize events")])
                }
                target.sendEvent(event)
            }
            return .object(["session": .string(tag.id), "window": .string(target === window ? "main" : "overlay"),
                            "x": .number(point.x), "y": .number(point.y)])
        }
        return .object(["error": .string("no agent cursor tag is shown")])
    }
}
#endif
