public import AppKit

/// The one owner of window ordering, key-window changes and app activation.
/// Under `CMUX_NEXT_NO_ACTIVATE=1` (``WindowPlacement/noActivate``) no path
/// makes a window key or activates the app: a relaunch must never take the
/// focus from the user's current app. Every call site that shows, raises or
/// focuses a window, or activates the app, goes through here.
@MainActor
public enum WindowActivation {
    /// Why a window is ordered in.
    public nonisolated enum Intent: Sendable, Equatable {
        /// A window appears (launch, restore, new window).
        case present
        /// Brings a window forward inside the app (key, no app activation).
        case raise
        /// The user or a CLI verb brings a window forward, focuses it and
        /// activates the app.
        case focus
    }

    /// How a window is ordered in, and whether the app activates.
    public nonisolated struct Plan: Sendable, Equatable {
        public enum Order: Sendable, Equatable {
            case makeKeyAndOrderFront
            case orderFrontRegardless
            case orderBack
        }

        public var order: Order
        public var activatesApp: Bool
    }

    /// The pure rule. No-activate never makes a window key and never
    /// activates: a presented window goes behind the others (or in front
    /// on an agent's test screen), a focused one is ordered front without
    /// the keys.
    public nonisolated static func plan(_ intent: Intent, noActivate: Bool, testScreen: Bool) -> Plan {
        guard noActivate else { return Plan(order: .makeKeyAndOrderFront, activatesApp: intent == .focus) }
        switch intent {
        case .present: return Plan(order: testScreen ? .orderFrontRegardless : .orderBack, activatesApp: false)
        case .raise, .focus: return Plan(order: .orderFrontRegardless, activatesApp: false)
        }
    }

    /// Orders `window` in for `intent` by the rule.
    public static func show(_ window: NSWindow, _ intent: Intent) {
        let plan = plan(intent, noActivate: WindowPlacement.noActivate, testScreen: WindowPlacement.testScreen != nil)
        if window.isMiniaturized, intent != .present { window.deminiaturize(nil) }
        switch plan.order {
        case .makeKeyAndOrderFront: window.makeKeyAndOrderFront(nil)
        case .orderFrontRegardless: window.orderFrontRegardless()
        case .orderBack: window.orderBack(nil)
        }
        if plan.activatesApp { NSApp.activate() }
    }

    /// Activates the app, unless launched with no-activate.
    public static func activateApp() {
        guard !WindowPlacement.noActivate else { return }
        NSApp.activate()
    }
}
