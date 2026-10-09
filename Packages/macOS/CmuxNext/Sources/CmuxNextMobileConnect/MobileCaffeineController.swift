public import CmuxMobileHost
import Foundation

/// Owns the Mac process assertion used by the phone's Keep Mac Awake control.
/// The assertion token never crosses the link and is released when this host
/// run is torn down.
public final class MobileCaffeineController: MobileCaffeineControl, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: (any NSObjectProtocol)?

    public init() {}

    public func status() async -> Bool { statusSync() }

    public func statusSync() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activity != nil
    }

    public func set(enabled: Bool) async throws { setSync(enabled: enabled) }

    public func setSync(enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if enabled {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "cmux Keep Mac Awake")
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// Toggles the same assertion used by the phone RPC and the Mac action.
    public func toggle() { setSync(enabled: !statusSync()) }

    deinit {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
