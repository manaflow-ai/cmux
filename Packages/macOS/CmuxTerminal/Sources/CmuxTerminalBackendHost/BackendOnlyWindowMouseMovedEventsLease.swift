internal import AppKit
internal import ObjectiveC

/// A composable window-scoped claim on AppKit mouse-moved delivery.
///
/// The first lease captures the caller's preexisting value. Overlapping cmux
/// terminal hosts share one associated state, and only the last release
/// restores that captured value.
@MainActor
final class BackendOnlyWindowMouseMovedEventsLease {
    private final class WindowState: NSObject {
        let originalValue: Bool
        var leaseCount = 0

        init(originalValue: Bool) {
            self.originalValue = originalValue
        }
    }

    private static var associationKey: UInt8 = 0

    private weak var window: NSWindow?
    private var state: WindowState?

    init(window: NSWindow) {
        let state: WindowState
        if let existing = objc_getAssociatedObject(
            window,
            &Self.associationKey
        ) as? WindowState {
            state = existing
        } else {
            state = WindowState(originalValue: window.acceptsMouseMovedEvents)
            objc_setAssociatedObject(
                window,
                &Self.associationKey,
                state,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        state.leaseCount += 1
        self.window = window
        self.state = state
        window.acceptsMouseMovedEvents = true
    }

    func invalidate() {
        guard let state else { return }
        self.state = nil
        guard let window else { return }
        state.leaseCount -= 1
        guard state.leaseCount == 0 else { return }
        window.acceptsMouseMovedEvents = state.originalValue
        objc_setAssociatedObject(
            window,
            &Self.associationKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
