#if DEBUG
import CmuxUpdater
public import Foundation
import Darwin

/// The update harness (DEV builds only; scripts/cmux-next/update-harness):
/// a tagged DEV build runs the real Sparkle flow against a loopback test
/// appcast whose items are signed with a throwaway EdDSA key, and writes
/// the update's timeline (check, stage, click, relaunch, the next launch's
/// marks) to a file the harness reads.
///
/// Only the bundle's Info.plist turns it on: the harness script adds
/// `SUPublicEDKey` (the throwaway key it generated) and
/// `CMUXNextUpdateHarness = {feed, marks}` to its own copies of a built
/// DEV app. Nothing in the repository sets either key, a DEV bundle
/// identifier is required, the feed must be a loopback URL, and Release
/// builds (stable, NIGHTLY, RC) compile none of this.
nonisolated public struct UpdateHarness: Sendable, Equatable {
    public static let infoKey = "CMUXNextUpdateHarness"

    /// The loopback appcast every check reads.
    public let feedURL: String
    /// The timeline file (one JSON object per line, appended).
    public let marksPath: String

    public init?(info: [String: Any], bundleIdentifier: String?) {
        guard UpdateTrack.isDevelopmentBundle(bundleIdentifier),
              let entry = info[Self.infoKey] as? [String: Any],
              let feed = entry["feed"] as? String, Self.isLoopback(feed),
              let marks = entry["marks"] as? String, marks.hasPrefix("/") else { return nil }
        feedURL = feed
        marksPath = marks
    }

    /// The running app's harness, or nil (every build that is not a
    /// harness copy).
    public static let current = UpdateHarness(info: Bundle.main.infoDictionary ?? [:],
                                              bundleIdentifier: Bundle.main.bundleIdentifier)

    /// http or https on 127.0.0.1, ::1 or localhost only.
    static func isLoopback(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "::1", "localhost"].contains(host)
    }

    /// Records `name` at `date` for this process. One O_APPEND write per
    /// line (about 100 bytes), so lines from the old and the new app never
    /// interleave; a failed write is dropped (the timeline is evidence,
    /// never a reason to change the update).
    public func mark(_ name: String, at date: Date = Date()) {
        let line = "{\"pid\":\(getpid()),\"name\":\"\(name)\",\"unix_ms\":\(Int64((date.timeIntervalSince1970 * 1_000).rounded()))}\n"
        let fd = open(marksPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.utf8CString.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }

    /// ``mark(_:at:)`` on the running app's harness; no-op without one.
    public static func mark(_ name: String, at date: Date = Date()) {
        current?.mark(name, at: date)
    }

    /// Sparkle for a DEV build that is a harness copy: the real driver on
    /// the loopback feed, never prompting; nil for any other build (a
    /// release identity runs its own driver, a DEV build without
    /// `SUPublicEDKey` runs none).
    @MainActor
    func controller(identity: UpdateBuildIdentity, log: UpdateLogBuffer, defaults: UserDefaults,
                    policy: ManagedUpdatePolicy) -> UpdateController? {
        guard identity.track == .development, identity.hasPublicKey else { return nil }
        let controller = UpdateController(log: log, defaults: defaults, isDevLikeBundle: false,
                                          isDisabledByPolicy: { policy.disablesUpdates })
        controller.installsUpdatesInBackground = true
        controller.feedOverride = feedURL
        log.append("update harness: Sparkle on the loopback feed \(feedURL)")
        mark("process_start", at: Self.processStart)
        mark("updater_created")
        return controller
    }

    /// The kernel's start time of this process.
    public static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
#endif
