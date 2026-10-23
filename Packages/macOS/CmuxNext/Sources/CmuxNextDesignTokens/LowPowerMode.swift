public import Foundation
internal import CmuxNextCompat

/// macOS Low Power Mode, observed once for the app. It follows
/// `NSProcessInfoPowerStateDidChange` (no polling); `override` replaces the
/// system value (the `debug.low_power_mode` socket method and tests).
@MainActor
public final class LowPowerMode {
    /// The app's observer of the system power state.
    public static let system = LowPowerMode(center: .default) { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Whether Low Power Mode is on: `override` when set, else the system value.
    public private(set) var isEnabled: Bool
    /// Replaces the system value; nil follows macOS again.
    public var override: Bool? {
        didSet { update() }
    }

    private var systemEnabled: Bool
    private let read: () -> Bool
    private let handlers = MainActorHandlers<Bool>()
    private var notifications: Task<Void, Never>?

    /// Follows `read` each time `center` posts a power state change.
    public init(center: NotificationCenter, read: @escaping () -> Bool) {
        self.read = read
        systemEnabled = read()
        isEnabled = systemEnabled
        notifications = Task { [weak self, center] in
            for await _ in center.notifications(named: .NSProcessInfoPowerStateDidChange) {
                guard let self else { return }
                self.systemEnabled = self.read()
                self.update()
            }
        }
    }

    /// A fixed system value that only `override` changes (tests).
    public init(enabled: Bool) {
        read = { enabled }
        systemEnabled = enabled
        isEnabled = enabled
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // The task handle is Sendable and cancels from any thread: a release off main stops the loop too.
    nonisolated deinit {
        notifications?.cancel()
    }

    /// Calls `handler` with the new value each time Low Power Mode turns on
    /// or off, until the returned observation is released (on any thread) or cancelled.
    public func observe(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) -> LowPowerModeObservation {
        LowPowerModeObservation(handlers.add(handler))
    }

    private func update() {
        let enabled = override ?? systemEnabled
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        handlers.call(enabled)
    }
}
