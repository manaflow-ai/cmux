public import Foundation

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
    fileprivate var handlers: [UUID: (Bool) -> Void] = [:]
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

    isolated deinit {
        notifications?.cancel()
    }

    /// Calls `handler` with the new value each time Low Power Mode turns on
    /// or off, until the returned observation is released or cancelled.
    public func observe(_ handler: @escaping (Bool) -> Void) -> LowPowerModeObservation {
        let id = UUID()
        handlers[id] = handler
        return LowPowerModeObservation(source: self, id: id)
    }

    private func update() {
        let enabled = override ?? systemEnabled
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        for handler in handlers.values { handler(enabled) }
    }
}

/// One `LowPowerMode.observe` registration; releasing it stops the calls.
@MainActor
public final class LowPowerModeObservation {
    private weak var source: LowPowerMode?
    private let id: UUID

    fileprivate init(source: LowPowerMode, id: UUID) {
        self.source = source
        self.id = id
    }

    isolated deinit {
        cancel()
    }

    /// Stops the calls.
    public func cancel() {
        source?.handlers[id] = nil
    }
}
