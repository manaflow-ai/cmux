import Foundation

/// Pushes a `terminal.updated` event to subscribed mobile clients on every
/// Ghostty frame draw. The metal layer already calls
/// `enqueueRenderedFrameUpdate()` when it acquires a drawable and the
/// `GhosttyRenderedFrameNotificationDemand` gate is active, which posts
/// `.ghosttyDidRenderFrame` once per coalesced frame. By retaining the demand
/// from this observer for the lifetime of the process, every grid mutation
/// (PTY echo, autosuggest ghost text, alt-screen redraws, mac-typed input)
/// becomes a push event the iPhone can act on without waiting for the poller.
@MainActor
final class MobileTerminalRenderObserver {
    static let shared = MobileTerminalRenderObserver()

    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        releaseFrameDemand = GhosttyNSView.retainRenderedFrameNotifications()
        releaseTickDemand = GhosttyApp.retainTickNotifications()
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { notification in
            // Cap the work per frame at a notification dispatch. The metal
            // layer coalesces frames before posting, so this fires at most
            // once per drawable.
            guard let view = notification.object as? GhosttyNSView,
                  let surfaceID = view.terminalSurface?.id else {
                return
            }
            MobileHostService.shared.emitEvent(
                topic: "terminal.updated",
                payload: ["surface_id": surfaceID.uuidString]
            )
        })
        // Frame notifications only fire when Ghostty's Metal layer pulls a
        // drawable, which it skips for surfaces whose Mac window isn't on
        // screen. Tick notifications fire on every Ghostty IO cycle (PTY
        // wakeup, action, render request) regardless of visibility, so a
        // background workspace driven by output still pushes updates to
        // the iPhone. The iPhone's snapshot refresh dedupes consecutive
        // events so the extra fan-out is harmless.
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { _ in
            MobileHostService.shared.emitEvent(
                topic: "terminal.updated",
                payload: [:]
            )
        })
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        releaseFrameDemand?()
        releaseFrameDemand = nil
        releaseTickDemand?()
        releaseTickDemand = nil
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        releaseFrameDemand?()
        releaseTickDemand?()
    }
}
