import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextAppearance

// The app and window notices that end or move a card (`HoverCardCoordinator`).
extension HoverCardCoordinator {
    /// App and window notifications, installed with the first source (a coordinator that never gets one, such
    /// as a strip's default before the App injects the shared one, costs nothing). The app going inactive and a
    /// Space change are subscriptions on the app's one ``AppEvents`` per center (recipe R-notif); the geometry
    /// notices stay observers, since the hit test needs the window that posted them.
    func installObserversIfNeeded() {
        guard hoverCardsWatch == nil else { return }
        hoverCardsWatch = DesignSettings.shared.signals.subscribe([.hoverCards], owner: "HoverCardCoordinator") { [weak self] in
            self?.hoverCardsSettingChanged()
        }
        if let appEvents {
            appWatches.append(appEvents.subscribe(NSApplication.didResignActiveNotification, owner: "HoverCardCoordinator") { [weak self] in
                if !WindowPlacement.noActivate { self?.dismiss(.appDeactivated) }
            })
        }
        if let workspaceEvents {
            appWatches.append(workspaceEvents.subscribe(NSWorkspace.activeSpaceDidChangeNotification, owner: "HoverCardCoordinator") { [weak self] in
                self?.dismiss(.windowResignedKey)
            })
        }
        let center = NotificationCenter.default
        // raw-observer-allow: the hit test needs the moved window, the notices' sender; an AppEvents call carries no sender
        let moves = [NSWindow.didMoveNotification, NSWindow.didResizeNotification]
        // raw-observer-allow: the hit test needs the moved window, the notices' sender; an AppEvents call carries no sender
        let ends = [NSWindow.didEndLiveResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
        for name in moves + ends {
            let ended = ends.contains(name)
            observers.append(MainActorObservation(name, center: center, read: { ($0.object as? NSWindow)?.windowNumber }) { [weak self] number in
                self?.windowGeometryChanged(number, liveResizeEnded: ended)
            })
        }
    }
}
