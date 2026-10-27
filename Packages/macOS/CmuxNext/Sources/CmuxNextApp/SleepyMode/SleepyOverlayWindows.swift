import AppKit
import CmuxNextWakeups

/// Covers every screen with a ``SleepyOverlayWindow`` showing ``SleepySceneView``,
/// rebuilt when screens change while it shows.
@MainActor
final class SleepyOverlayWindows: SleepyOverlayPresenting {
    private let workingAgents: @MainActor () -> Int
    private let lockMac: @MainActor () -> Void
    private var windows: [SleepyOverlayWindow] = []
    private var wake: (@MainActor () -> Void)?
    private let events: AppEvents
    /// Follows `didChangeScreenParametersNotification` while the scene shows; cancelled on hide.
    private var screenWatch: EventSubscription?

    /// - Parameters:
    ///   - events: the app's notices (`AppServices.appEvents`): a screen change rebuilds the windows in its turn.
    ///   - workingAgents: the count of this Mac's agents running a turn, read again when an observed fact it read changes.
    ///   - lockMac: the scene's Lock Mac button.
    init(events: AppEvents, workingAgents: @escaping @MainActor () -> Int, lockMac: @escaping @MainActor () -> Void) {
        self.events = events
        self.workingAgents = workingAgents
        self.lockMac = lockMac
    }

    var isShowing: Bool { wake != nil }

    func show(wake: @escaping @MainActor () -> Void) {
        self.wake = wake
        rebuild()
        NSApp.unhide(nil)
        NSApp.activate()
        screenWatch?.cancel()
        screenWatch = events.subscribe(NSApplication.didChangeScreenParametersNotification, owner: "SleepyOverlay.screens") { [weak self] in
            guard let self, self.isShowing else { return }
            self.rebuild()
        }
    }

    func hide() {
        wake = nil
        screenWatch?.cancel()
        screenWatch = nil
        tearDown()
    }

    private func rebuild() {
        tearDown()
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            let window = SleepyOverlayWindow(screen: screen, frame: screen.frame)
            window.onWake = { [weak self] in self?.wake?() }
            window.contentView = SleepySceneView.hostView(workingAgents: workingAgents,
                                                          wake: { [weak self] in self?.wake?() },
                                                          lockMac: lockMac)
            windows.append(window)
            window.orderFrontRegardless()
        }
        windows.first?.makeKeyAndOrderFront(nil)
    }

    private func tearDown() {
        for window in windows {
            window.onWake = nil
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}
