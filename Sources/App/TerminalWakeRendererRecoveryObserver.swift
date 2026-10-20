import AppKit

/// Routes system and display wake notifications into one coalesced terminal
/// renderer recovery pass.
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
        return [didWake, screensDidWake]
    }
}
