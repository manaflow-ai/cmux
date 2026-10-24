#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextSettings

/// `debug.hints` (DEBUG builds): whether hint mode shows, what is typed, and
/// each label with its control (role, title, window rect), plus the menu
/// AppKit tracks now (a Shift label opens a context menu), for
/// scripts/cmux-next/hint-mode-e2e.py and jump-keys-e2e.py. `dismiss_menu`
/// closes that menu; `pick_menu: <title>` runs that item's action, as a click does.
@MainActor
enum DebugHints {
    private static var tracked: NSMenu?
    private static var observers: [MainActorObservation] = []

    /// Starts following menu tracking (once, when the method registers).
    static func watchMenus() {
        guard observers.isEmpty else { return }
        observers = [
            MainActorObservation(NSMenu.didBeginTrackingNotification, read: { $0.object as? NSMenu }) { menu in
                tracked = menu
            },
            MainActorObservation(NSMenu.didEndTrackingNotification, read: { ($0.object as AnyObject?).map(ObjectIdentifier.init) }) { menu in
                if tracked.map(ObjectIdentifier.init) == menu { tracked = nil }
            },
        ]
    }

    static func report(_ hints: WindowHintController, params: [String: JSONValue]) -> JSONValue {
        if let title = params["pick_menu"]?.stringValue, let open = tracked, let index = open.items.firstIndex(where: { $0.title == title }) {
            open.cancelTracking()
            open.performActionForItem(at: index)
            tracked = nil
        }
        let menu: JSONValue = tracked.map { menu in
            ["open": true, "items": .array(menu.items.map { .string($0.isSeparatorItem ? "-" : $0.title) })]
        } ?? ["open": false, "items": []]
        if params["dismiss_menu"]?.boolValue == true { tracked?.cancelTracking() }
        guard let shown = hints.shown else { return ["active": false, "typed": "", "hints": [], "menu": menu] }
        return [
            "active": true,
            "typed": .string(shown.typed),
            "menu": menu,
            "hints": .array(shown.hints.map { hint in
                let rect = hint.target.rect
                return [
                    "label": .string(hint.label), "role": .string(hint.target.role), "title": .string(hint.target.title),
                    "x": .number(Double(rect.minX)), "y": .number(Double(rect.minY)),
                    "width": .number(Double(rect.width)), "height": .number(Double(rect.height)),
                ]
            }),
        ]
    }
}
#endif
