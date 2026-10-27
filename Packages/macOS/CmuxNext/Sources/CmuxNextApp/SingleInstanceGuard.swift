import AppKit
import CmuxNextUpdater
import Darwin

/// One copy of a cmux bundle per user session (field log, 2026-10-26: a NIGHTLY started by direct exec from an
/// ssh session while the first copy ran; its Chromium could not start, since the first copy holds the profile in
/// `<Application Support>/<bundle id>/Chromium`, so every restored Chromium tab loaded in WebKit, signed out).
///
/// A second copy of the same bundle id, same user, hands its URLs and files to the running copy, asks it to come
/// forward, and exits, all before it reads a session, the relaunch-focus record, the daemon or CEF.
/// `LSMultipleInstancesProhibited` is not used: it does nothing for a direct exec (the copy above), and it refuses
/// the same app in another user's session, which fleet machines run.
///
/// Not guarded: DEV and staging bundles (harnesses run a tagged bundle beside another copy of it; their own
/// bundle ids keep their data apart) and a launch with `CMUX_NEXT_ALLOW_SECOND_INSTANCE=1`. DEV, NIGHTLY and stable
/// have different bundle ids, so they never see each other here. Sparkle's relaunch starts the new build only
/// after the old process exited (its installer waits on the old pid), so a relaunch finds no peer.
nonisolated struct SingleInstanceGuard: Equatable, Sendable {
    /// A running process of this bundle, as LaunchServices and the kernel report it.
    struct Peer: Equatable, Sendable {
        var pid: pid_t
        /// The process's real user id, nil when the kernel no longer knows the pid.
        var uid: uid_t?
        var bundleURL: URL?
        var launchDate: Date?
        var isTerminated: Bool
    }

    enum Decision: Equatable, Sendable {
        /// Start normally.
        case launch
        /// Forward to `peer` and exit; `activates` is false for an agent launch (`CMUX_NEXT_NO_ACTIVATE=1`).
        case handOff(Peer, activates: Bool)
    }

    static let allowKey = "CMUX_NEXT_ALLOW_SECOND_INSTANCE"

    var bundleIdentifier: String?
    var pid: pid_t
    var uid: uid_t
    var environment: [String: String]

    /// The decision for this process given the running copies of its bundle.
    func decide(peers: [Peer]) -> Decision {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              !UpdateTrack.isDevelopmentBundle(bundleIdentifier),
              environment[Self.allowKey] != "1" else { return .launch }
        // A peer whose uid the kernel no longer has exited after LaunchServices listed it.
        let running = peers.filter { $0.pid != pid && $0.pid > 0 && !$0.isTerminated && $0.uid == uid }
        guard let first = running.min(by: { ($0.launchDate ?? .distantFuture, $0.pid) < ($1.launchDate ?? .distantFuture, $1.pid) })
        else { return .launch }
        return .handOff(first, activates: environment["CMUX_NEXT_NO_ACTIVATE"] != "1")
    }
}

@MainActor extension SingleInstanceGuard {
    /// This process.
    static var current: SingleInstanceGuard {
        SingleInstanceGuard(bundleIdentifier: Bundle.main.bundleIdentifier, pid: getpid(), uid: getuid(),
                            environment: ProcessInfo.processInfo.environment)
    }

    /// The running copies of `bundleIdentifier` in this session (LaunchServices), with the kernel's uid.
    static func peers(of bundleIdentifier: String) -> [Peer] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map { app in
            Peer(pid: app.processIdentifier, uid: Self.uid(of: app.processIdentifier), bundleURL: app.bundleURL,
                 launchDate: app.launchDate, isTerminated: app.isTerminated)
        }
    }

    /// The real uid of `pid`, nil when no such process exists (it exited).
    static func uid(of pid: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_pcred.p_ruid
    }

    /// The decision for this launch.
    func resolve() -> Decision {
        guard let bundleIdentifier else { return .launch }
        return decide(peers: Self.peers(of: bundleIdentifier))
    }
}
