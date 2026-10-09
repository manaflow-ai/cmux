import CmuxMobileHost
import Foundation

/// Owns the Mac process assertion used by the phone's Keep Mac Awake control.
/// The assertion token never crosses the link and is released when this host
/// run is torn down.
public final class MobileCaffeineController: MobileCaffeineControl, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: (any NSObjectProtocol)?

    public init() {}

    public func status() async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activity != nil
    }

    public func set(enabled: Bool) async throws {
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

    deinit {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
