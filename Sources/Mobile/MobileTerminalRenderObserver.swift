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

    private var releaseDemand: (() -> Void)?
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        releaseDemand = GhosttyNSView.retainRenderedFrameNotifications()
        observer = NotificationCenter.default.addObserver(
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
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        releaseDemand?()
        releaseDemand = nil
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        releaseDemand?()
    }
}
