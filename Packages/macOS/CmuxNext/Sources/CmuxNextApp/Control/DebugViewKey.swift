#if DEBUG
import AppKit
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.view_key` {view, key, modifiers?, window?} (DEBUG builds, cx-tupd):
/// makes the named view its window's first responder, then sends a real
/// key-down and key-up for `key` (names as `debug.key`: left, down, tab,
/// return, space, a typed character) the way a keyboard does: the key-down
/// goes through `debug.key`'s dispatch (app shortcuts, key equivalents, then
/// the responder chain from that view), the key-up to the window. So focus
/// rings and keyboard paths run as for a user, also in a window that is
/// never key (`CMUX_NEXT_NO_ACTIVATE=1`), where `debug.key` alone reaches
/// whatever had focus (a terminal), not the sidebar.
///
/// Returns the first responder class before and after, `handled_by`
/// (`debug.key`'s verdict), and `handled`: false when the key-down went up
/// the whole responder chain without a taker (where AppKit would beep).
/// `window` is a window number (as `debug.pointer_hover`) or a window id
/// (as `debug.key`); the default is the active main window.
///
/// `debug.focus_ring` {window?}: the sidebar's keyboard focus without
/// pixels: the focused group, whether the keyboard put it there, and each
/// group header with the ring its view draws now.
@MainActor
enum DebugViewKey {
    typealias Resolver = @MainActor (WindowController) -> NSView?

    /// Named key views. Another view joins with ``register(_:_:)``.
    private static var views: [String: Resolver] = [
        "sidebar.list": { $0.sidebar.container.sidebarView.debugKeyView },
        // Whatever in the sidebar has keyboard focus now, so presses walk on from it (cx-qno.10).
        "sidebar.focus": { controller in
            let sidebar = controller.sidebar.container.sidebarView
            guard let view = controller.window?.firstResponder as? NSView, view.isDescendant(of: sidebar) else { return sidebar.debugKeyView }
            return view
        },
    ]

    /// Makes `view(controller)` reachable as `debug.view_key` view `name`.
    static func register(_ name: String, _ view: @escaping Resolver) { views[name] = view }

    static func send(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let controller = controller(params, services: services), let window = controller.window else {
            return .object(["error": .string("no window")])
        }
        let name = params["view"]?.stringValue ?? ""
        guard let resolve = views[name] else {
            return .object(["error": .string("unknown view"), "views": .array(views.keys.sorted().map(JSONValue.string))])
        }
        guard let view = resolve(controller), view.window === window, !view.isHiddenOrHasHiddenAncestor else {
            return .object(["error": .string("view \(name) is not shown in that window")])
        }
        let before = responderName(window.firstResponder)
        guard window.firstResponder === view || window.makeFirstResponder(view) else {
            return .object(["error": .string("view \(name) refused first responder"), "first_responder": .string(before)])
        }
        let key = params["key"]?.stringValue ?? ""
        let modifiers = params["modifiers"]?.arrayValue ?? []
        // A sentinel past the chain's last responder: a key-down that reaches
        // it had no taker (AppKit would beep), so it reports `handled` false.
        let end = EndOfChain()
        var last: NSResponder = window
        for _ in 0..<64 { guard let next = last.nextResponder else { break }; last = next }
        let previousNext = last.nextResponder
        last.nextResponder = end
        defer { if last.nextResponder === end { last.nextResponder = previousNext } }
        let down = DebugKey.send(["window": .string(controller.state.id), "key": .string(key), "modifiers": .array(modifiers)],
                                 services: services)
        let press = DebugKey.keyPress(key, modifiers: modifiers.compactMap(\.stringValue))
        if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: press.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: press.characters,
                                     charactersIgnoringModifiers: press.characters, isARepeat: false, keyCode: press.keyCode) {
            if DebugNativeInput.usesAppKitPath(window) { DebugNativeInput.sendThroughApp([up]) } else { window.sendEvent(up) }
        }
        var report: [String: JSONValue] = [
            "window": .number(Double(window.windowNumber)), "view": .string(name), "made_first_responder": .bool(true),
            "first_responder_before": .string(before), "first_responder": .string(responderName(window.firstResponder)),
            "handled": .bool(!end.reachedKeyDown), "focus_ring": focusRing(controller),
        ]
        if case let .object(fields) = down {
            for field in ["handled_by", "action", "error"] { if let value = fields[field] { report[field] = value } }
        }
        return .object(report)
    }

    static func focusRingReport(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let controller = controller(params, services: services), let window = controller.window else {
            return .object(["error": .string("no window")])
        }
        guard case var .object(report) = focusRing(controller) else { return .null }
        report["window"] = .number(Double(window.windowNumber))
        report["first_responder"] = .string(responderName(window.firstResponder))
        return .object(report)
    }

    private static func focusRing(_ controller: WindowController) -> JSONValue {
        let ring = controller.sidebar.container.sidebarView.debugFocusRing()
        return .object([
            "focused_group": ring.focusedGroup.map(JSONValue.string) ?? .null,
            "ring_shown": .bool(ring.ringShown),
            "headers": .array(ring.headers.map { header in
                .object([
                    "group": .string(header.group), "name": .string(header.name),
                    "ring_drawn": header.ringDrawn.map(JSONValue.bool) ?? .null,
                    "window_frame": .object(["x": .number(header.windowFrame.minX), "y": .number(header.windowFrame.minY),
                                             "width": .number(header.windowFrame.width), "height": .number(header.windowFrame.height)]),
                ])
            }),
        ])
    }

    /// `window`: a window number or a window id; default the active main window.
    private static func controller(_ params: [String: JSONValue], services: AppServices) -> WindowController? {
        if let number = params["window"]?.intValue {
            return services.windows.controllers.first { $0.window?.windowNumber == number }
        }
        if let id = params["window"]?.stringValue {
            return services.windows.controllers.first { $0.state.id == id || $0.window.map { String($0.windowNumber) } == id }
        }
        return services.windows.active ?? services.windows.controllers.first
    }

    /// The responder's class, with its accessibility label when it has one (a sidebar item).
    private static func responderName(_ responder: NSResponder?) -> String {
        guard let responder else { return "none" }
        let label = (responder as? NSView)?.accessibilityLabel().map { " " + $0 } ?? ""
        return String(describing: type(of: responder)) + label
    }

    private final class EndOfChain: NSResponder {
        private(set) var reachedKeyDown = false
        override func keyDown(with event: NSEvent) { reachedKeyDown = true }
        override func keyUp(with event: NSEvent) {}
    }
}
#endif
