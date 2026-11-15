public import AppKit

/// The menus AppKit tracks, as it posts `NSMenu.didBeginTrackingNotification` and
/// `didEndTrackingNotification`: delivered at once, in the poster's own call, on the main actor (a
/// press that opens a menu sees it before the press returns). The one seam for those two system
/// notices (plans/cmux-next/PATTERNS.md P2, P3): an owner keeps one while it follows menus and
/// subscribes; releasing it stops observing.
@MainActor
public final class MenuTracking {
    /// A menu began or ended tracking.
    public enum Change {
        case began(NSMenu)
        case ended(NSMenu)
    }

    private var subscribers: [(Change) -> Void] = []
    private var observations: [MainActorObservation] = []

    /// - Parameter center: Where the menus' notices are posted (tests pass their own).
    public init(center: NotificationCenter = .default) {
        observations = [
            MainActorObservation(NSMenu.didBeginTrackingNotification, center: center, atOnce: true, read: { $0.object as? NSMenu }) { [weak self] menu in
                if let menu { self?.send(.began(menu)) }
            },
            MainActorObservation(NSMenu.didEndTrackingNotification, center: center, atOnce: true, read: { $0.object as? NSMenu }) { [weak self] menu in
                if let menu { self?.send(.ended(menu)) }
            },
        ]
    }

    /// Calls `handler` with each change from now on, until this is released.
    public func subscribe(_ handler: @escaping (Change) -> Void) {
        subscribers.append(handler)
    }

    /// Runs `work` once, at the first menu that begins tracking from now on, on the main actor's next turn (served
    /// while the menu tracks), so the menu is not held up by it: work made ahead of something a menu item opens (the
    /// app's web overlay pages, made on this sign of intent and not at launch). Later menus cost one check.
    public func onFirstMenu(_ work: @escaping @MainActor () -> Void) {
        var pending: (@MainActor () -> Void)? = work
        subscribe { change in
            guard case .began = change, let run = pending else { return }
            pending = nil
            // task-owner: one ordering hop past the menu's begin-tracking post; it ends with `work`
            Task { @MainActor in run() }
        }
    }

    /// Runs `work` at each menu that begins tracking, on the main actor's next turn (as ``onFirstMenu(_:)``): work made
    /// ahead of something a menu item opens that is freed again when unused (the app's web overlay pages), so `work`
    /// makes it again or keeps it, and costs little when it is already made.
    public func onMenus(_ work: @escaping @MainActor () -> Void) {
        subscribe { change in
            guard case .began = change else { return }
            // task-owner: one ordering hop past the menu's begin-tracking post; it ends with `work`
            Task { @MainActor in work() }
        }
    }

    private func send(_ change: Change) {
        for subscriber in subscribers { subscriber(change) }
    }
}
