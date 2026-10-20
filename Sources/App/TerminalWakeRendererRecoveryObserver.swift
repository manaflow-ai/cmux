import AppKit

/// Routes sleep and wake notifications into one terminal renderer recovery
/// pass per wake episode.
@MainActor
struct TerminalWakeRendererRecoveryObserver {
    private let scheduler: TerminalWakeRendererRecoveryScheduler

    init() {
        scheduler = TerminalWakeRendererRecoveryScheduler()
    }

    init(scheduler: TerminalWakeRendererRecoveryScheduler) {
        self.scheduler = scheduler
    }

    func install(
        in notificationCenter: NotificationCenter,
        surfaces: @escaping @MainActor () -> [any TerminalWakeRendererRecoverable]
    ) -> [NSObjectProtocol] {
        let willSleep = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [scheduler] _ in
            MainActor.assumeIsolated {
                scheduler.prepareForSleep()
            }
        }
        let screensDidSleep = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [scheduler] _ in
            MainActor.assumeIsolated {
                scheduler.prepareForSleep()
            }
        }
        let didWake = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [scheduler] _ in
            MainActor.assumeIsolated {
                scheduler.schedule(
                    surfaces: surfaces,
                    reason: "workspace.didWake"
                )
            }
        }
        let screensDidWake = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [scheduler] _ in
            MainActor.assumeIsolated {
                scheduler.schedule(
                    surfaces: surfaces,
                    reason: "workspace.screensDidWake"
                )
            }
        }
        return [willSleep, screensDidSleep, didWake, screensDidWake]
    }
}
