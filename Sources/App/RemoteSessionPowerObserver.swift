import AppKit
import CmuxFoundation
import CmuxTerminal

@MainActor
protocol TerminalWakeRefreshable: AnyObject {
    var isRendererEffectivelyVisible: Bool { get }
    func forceRefresh(reason: String)
}

extension TerminalSurface: TerminalWakeRefreshable {}

/// Coalesces system and display wake notifications before refreshing visible
/// terminal renderers. Both notifications can arrive for one sleep/wake cycle,
/// and a single refresh after the wake state settles avoids racing AppKit's
/// window and display reattachment.
@MainActor
final class TerminalWakeRefreshScheduler {
    private let scheduler: MainActorDeferredActionScheduler

    init(scheduler: MainActorDeferredActionScheduler = MainActorDeferredActionScheduler()) {
        self.scheduler = scheduler
    }

    func schedule(
        surfaces: @escaping @MainActor () -> [any TerminalWakeRefreshable],
        reason: String
    ) {
        scheduler.schedule(zeroDelayPolicy: .yieldOnce) {
            for surface in surfaces() where surface.isRendererEffectivelyVisible {
                surface.forceRefresh(reason: reason)
            }
        }
    }
}

/// Adapts AppKit system-power notifications into main-actor lifecycle actions.
@MainActor
struct RemoteSessionPowerObserver {
    func install(
        in notificationCenter: NotificationCenter,
        onWillSleep: @escaping @MainActor () -> Void,
        onDidWake: @escaping @MainActor () -> Void,
        onScreensDidWake: @escaping @MainActor () -> Void = {}
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
        let screensDidWake = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onScreensDidWake() }
        }
        return [willSleep, didWake, screensDidWake]
    }
}
