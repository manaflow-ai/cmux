import AppKit

/// Adapts AppKit system-power notifications into main-actor lifecycle actions.
@MainActor
struct RemoteSessionPowerObserver {
    func install(
        in notificationCenter: NotificationCenter,
        onWillSleep: @escaping @MainActor () -> Void,
        onDidWake: @escaping @MainActor () -> Void
    ) -> [NSObjectProtocol] {
        let willSleep = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWillSleep() }
        }
        let didWake = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onDidWake() }
        }
        return [willSleep, didWake]
    }
}
