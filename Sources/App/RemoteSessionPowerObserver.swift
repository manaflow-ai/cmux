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
            MainActor.assumeIsolated {
#if DEBUG
                cmuxDebugLog("systemPower.willSleep")
#endif
                onWillSleep()
            }
        }
        let didWake = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
#if DEBUG
                cmuxDebugLog("systemPower.didWake")
#endif
                onDidWake()
            }
        }
        return [willSleep, didWake]
    }
}
