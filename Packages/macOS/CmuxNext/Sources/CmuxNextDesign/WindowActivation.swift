public import AppKit

/// The app's NSApplication when it can refuse activation: while it does (an update relaunch's
/// startup, `UpdateRelaunchFocus`), windows that open or come forward are ordered in without taking
/// key, so the app the user is in keeps the keyboard.
@MainActor public protocol ActivationRefusing: AnyObject {
    var refusesActivation: Bool { get }
}

/// The one owner of window ordering, key-window changes and app activation.
/// Under `CMUX_NEXT_NO_ACTIVATE=1` (``WindowPlacement/noActivate``) no path
/// makes a window key or activates the app: a relaunch must never take the
/// focus from the user's current app. Every call site that shows, raises or
/// focuses a window, or activates the app, goes through here.
@MainActor
public struct WindowActivation {
    public init() {}
    /// Why a window is ordered in.
    public nonisolated enum Intent: Sendable, Equatable {
        /// A window appears (launch, restore, new window).
        case present
        /// A window appears that this client's user did not ask to see
        /// (automation, Option on a tear-off): behind the others, never key.
        case presentBehind
        /// Brings a window forward inside the app (key, no app activation).
        case raise
        /// The user or a CLI verb brings a window forward, focuses it and
        /// activates the app.
        case focus
        /// Brings a window forward without making it key or activating the
        /// app: a link opened in the background (Cmd held) or by a script.
        case bringForward
    }

    /// How a window is ordered in, and whether the app activates.
    public nonisolated struct Plan: Sendable, Equatable {
        public enum Order: Sendable, Equatable {
            case makeKeyAndOrderFront
            case orderFrontRegardless
            /// In front of the app's other windows, without the keys.
            case orderFront
            case orderBack
        }

        public var order: Order
        public var activatesApp: Bool
    }

    /// The pure rule. Bring-forward orders a window front without the keys
    /// in every launch. No-activate never makes a window key and never
    /// activates: a presented window goes behind the others (or in front
    /// on an agent's test screen), a focused one is ordered front without
    /// the keys.
    /// `startsBehind` (an update relaunch's startup): a window that appears or is raised goes in
    /// front of the app's windows without the keys; a user's focus keeps its plan.
    public nonisolated static func plan(_ intent: Intent, noActivate: Bool, testScreen: Bool, startsBehind: Bool = false) -> Plan {
        // In front of the app's windows, never key, in any launch.
        if intent == .bringForward { return Plan(order: .orderFront, activatesApp: false) }
        if startsBehind, !noActivate, intent == .present || intent == .raise { return Plan(order: .orderFront, activatesApp: false) }
        if intent == .presentBehind {
            return Plan(order: noActivate && testScreen ? .orderFrontRegardless : .orderBack, activatesApp: false)
        }
        guard noActivate else { return Plan(order: .makeKeyAndOrderFront, activatesApp: intent == .focus) }
        switch intent {
        case .present, .presentBehind: return Plan(order: testScreen ? .orderFrontRegardless : .orderBack, activatesApp: false)
        case .raise, .focus, .bringForward: return Plan(order: .orderFrontRegardless, activatesApp: false)
        }
    }

    /// Told after ``show(_:_:)`` ordered `window` in: true in front of the app's windows, false
    /// behind them. The app's one record of its window order (the window registry's recency,
    /// saved as each window's restore order) follows it, together with key-window changes, so no
    /// path asks the window server for the order (cx-8w027.25).
    public static var didOrder: ((NSWindow, _ inFront: Bool) -> Void)?

    /// Orders `window` in for `intent` by the rule.
    public static func show(_ window: NSWindow, _ intent: Intent) {
        let plan = plan(intent, noActivate: WindowPlacement.noActivate, testScreen: WindowPlacement.testScreen != nil,
                        startsBehind: (NSApp as? any ActivationRefusing)?.refusesActivation == true)
        if window.isMiniaturized, intent != .present { window.deminiaturize(nil) }
        switch plan.order {
        case .makeKeyAndOrderFront: window.makeKeyAndOrderFront(nil)
        case .orderFrontRegardless: window.orderFrontRegardless()
        case .orderFront: window.orderFront(nil)
        case .orderBack: window.orderBack(nil)
        }
        didOrder?(window, plan.order != .orderBack)
        if plan.activatesApp { NSApp.activate() }
    }

    /// Orders `window` in at its place in `order` (front first; nil for a window not made yet),
    /// a restored window stack: below the nearest shown window in front of it, else above the
    /// nearest shown one behind it. Never key, never activates; the caller's order record
    /// already places it there. False (nothing ordered) when no other window of `order` shows.
    public static func restack(_ window: NSWindow, in order: [NSWindow?]) -> Bool {
        guard let index = order.firstIndex(where: { $0 === window }) else { return false }
        // A full-screen window is on its own Space: ordering against it could move the window there.
        let shown = { (other: NSWindow?) in other.flatMap { $0.isVisible && !$0.styleMask.contains(.fullScreen) ? $0 : nil } }
        if let front = order[..<index].reversed().lazy.compactMap(shown).first {
            window.order(.below, relativeTo: front.windowNumber)
        } else if let back = order[(index + 1)...].lazy.compactMap(shown).first {
            window.order(.above, relativeTo: back.windowNumber)
        } else {
            return false
        }
        return true
    }

    /// Activates the app, unless launched with no-activate.
    public static func activateApp() {
        guard !WindowPlacement.noActivate else { return }
        NSApp.activate()
    }
}
