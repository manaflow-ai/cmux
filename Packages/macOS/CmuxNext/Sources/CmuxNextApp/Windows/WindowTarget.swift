import AppKit

/// The window an input event came from, for the length of its dispatch
/// (`WindowManager.dispatching(eventFrom:_:)`).
struct EventOrigin {
    /// The cmux window that owns the event's window, or the window the event's own action made
    /// key since (`eventDidBringForward(_:)`).
    weak var controller: WindowController?
}

extension WindowManager {
    /// Runs `body`, the dispatch of an input event from `window` (`CmuxApplication.sendEvent`).
    /// While it runs, ``active`` is the cmux window that owns `window`, whatever window AppKit
    /// reports key: a click or key in window A acts in window A even while the key record names
    /// window B (the app activating after Cmd-Tab makes the window that was key at deactivation
    /// key again first; a key change still in flight). Only a window this app's own code makes key
    /// during the dispatch (New Window, Select Next Window: `WindowActivation.show`) takes over.
    /// A window no cmux window owns leaves ``active`` as it was.
    func dispatching<T>(eventFrom window: NSWindow?, _ body: () throws -> T) rethrows -> T {
        let previous = eventOrigin
        defer { eventOrigin = previous }
        if let window, let controller = owner(of: window) { eventOrigin = EventOrigin(controller: controller) }
        return try body()
    }

    /// The window the event in dispatch came from; nil outside an event's dispatch.
    var eventOriginWindow: WindowController? {
        guard let controller = eventOrigin?.controller, controllers.contains(where: { $0 === controller }) else { return nil }
        return controller
    }

    /// `WindowActivation` ordered `window` in front and made it key: during an event's dispatch the
    /// event's action asked for that window, which is the active one from now on.
    func eventDidBringForward(_ window: NSWindow) {
        guard eventOrigin != nil, services.keyWindowSource() === window, let controller = owner(of: window) else { return }
        eventOrigin = EventOrigin(controller: controller)
    }
}
