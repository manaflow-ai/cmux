import AppKit
import CmuxNextCompat
import Darwin
public import Foundation

/// One copy of a cmux bundle per user (field log, 2026-10-26: a NIGHTLY started by direct exec from an ssh session
/// while the first copy ran; its Chromium could not start, since the first copy holds the profile in
/// `<Application Support>/<bundle id>/Chromium`, so every restored Chromium tab loaded in WebKit, signed out).
///
/// The claim is an exclusive `flock` on `<Application Support>/<bundle id>/instance.lock`, held for the life of the
/// process (the kernel drops it when the process ends, however it ends). Two launches racing each other cannot
/// both get it. The owner then writes its pid, bundle path and executable beside it, in `instance.owner`
/// (``Owner``, replaced atomically, off the main thread). A copy that
/// cannot get it hands its URLs and files to that exact bundle and exits (`SingleInstanceHandoff`), before it
/// reads the relaunch-focus record, a session, the daemon or CEF. Never by bundle id: an older copy registered
/// under the same id may be what LaunchServices picks (nightly proof, 2026-10-27: `open -b` started an older
/// NIGHTLY with no guard, whose Chromium could not start).
/// `LSMultipleInstancesProhibited` is not used: it does nothing for a direct exec (the copy above).
///
/// Not guarded: DEV and staging bundles (harnesses run a tagged bundle beside another copy of it; their own bundle
/// ids keep their data apart) and a launch with `CMUX_NEXT_ALLOW_SECOND_INSTANCE=1`. DEV, NIGHTLY and stable have
/// different bundle ids, so different locks. Sparkle's relaunch starts the new build only after the old process
/// exited (its installer waits on the old pid), so the lock is free by then.
public nonisolated struct SingleInstanceGuard: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Start normally (this process owns the claim, or is not guarded).
        case launch
        /// Another copy owns the claim: hand off to it and exit, never start. `activates` is false for an agent
        /// launch (`CMUX_NEXT_NO_ACTIVATE=1`), which then forwards nothing (an open would bring the owner forward).
        case handOff(activates: Bool)
    }

    /// What proves a pid is still the copy that wrote a record: its executable and its start time. A reused pid
    /// (even one running the same executable) has a later start time.
    public nonisolated struct Identity: Equatable, Sendable {
        /// The executable, symlinks resolved.
        public var executablePath: String
        /// The kernel's start time of the process, `seconds.microseconds`.
        public var started: String

        public init(executablePath: String, started: String) {
            self.executablePath = executablePath
            self.started = started
        }
    }

    /// The copy that holds the claim, as it recorded itself in `instance.owner`.
    public nonisolated struct Owner: Equatable, Sendable {
        public var pid: pid_t
        /// Its `.app` bundle: where the hand-off sends the URLs (`open -a`).
        public var bundlePath: String
        /// Proves `pid` is still that copy.
        public var identity: Identity

        public init(pid: pid_t, bundlePath: String, identity: Identity) {
            self.pid = pid
            self.bundlePath = bundlePath
            self.identity = identity
        }

        /// The record's contents: one line each for the pid, the bundle path, the executable and the start time.
        public var record: String { "\(pid)\n\(bundlePath)\n\(identity.executablePath)\n\(identity.started)\n" }

        public init?(record: String) {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 4, let pid = pid_t(lines[0]), pid > 0, !lines[1].isEmpty, !lines[2].isEmpty, !lines[3].isEmpty
            else { return nil }
            self.init(pid: pid, bundlePath: String(lines[1]),
                      identity: Identity(executablePath: String(lines[2]), started: String(lines[3])))
        }
    }

    /// The outcome of trying to take the claim.
    public enum Claim: Equatable, Sendable {
        /// This process holds it.
        case held
        /// Another live process holds it.
        case taken
        /// No claim could be tried (no Application Support directory, a file error): launch as before.
        case unavailable
    }

    public static let allowKey = "CMUX_NEXT_ALLOW_SECOND_INSTANCE"

    public var bundleIdentifier: String?
    public var environment: [String: String]

    public init(bundleIdentifier: String?, environment: [String: String]) {
        self.bundleIdentifier = bundleIdentifier
        self.environment = environment
    }

    /// Whether this launch takes part in the claim at all.
    public var isGuarded: Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return !UpdateTrack.isDevelopmentBundle(bundleIdentifier) && environment[Self.allowKey] != "1"
    }

    /// The decision for this launch given the claim's outcome: a taken claim never starts a second copy.
    public func decide(_ claim: Claim) -> Decision {
        guard isGuarded, claim == .taken else { return .launch }
        return .handOff(activates: environment["CMUX_NEXT_NO_ACTIVATE"] != "1")
    }
}

public nonisolated extension SingleInstanceGuard {
    /// This process.
    static var current: SingleInstanceGuard {
        SingleInstanceGuard(bundleIdentifier: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment)
    }

    /// The lock file of `bundleIdentifier`.
    static func lockURL(bundleIdentifier: String,
                        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first) -> URL? {
        applicationSupport?.appending(path: bundleIdentifier).appending(path: "instance.lock")
    }

    /// The owner record beside the lock file at `lockURL` (`instance.owner`).
    static func ownerURL(lockURL: URL) -> URL {
        lockURL.deletingLastPathComponent().appending(path: "instance.owner")
    }

    /// Takes the claim at `url`, keeping the descriptor open (close-on-exec, so no child keeps it) for the life of
    /// the process. Only a lock another process holds is `.taken`; any file error launches as before.
    static func claim(at url: URL) -> Claim {
        // blocking-allow: runs once in `main` before NSApp exists and before any other thread starts; whether this copy may start at all decides everything after it, so nothing can run first (one mkdir of an existing folder)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(fd)
            return lockError == EWOULDBLOCK ? .taken : .unavailable
        }
        return .held  // fd stays open: the claim lasts until this process ends
    }

    /// Writes `owner` to `url` by an atomic replace (a temporary file renamed over it), so a reader sees the
    /// whole previous record or the whole new one, never a partial one. Call it off the main thread. A write
    /// that fails leaves the hand-off unresolved, so a second copy launches nothing.
    static func writeOwner(_ owner: Owner, at url: URL) {
        try? Data(owner.record.utf8).blockingWrite(to: url, options: .atomic)
    }

    /// The running copy recorded at `url` (``ownerURL(lockURL:)``), if its pid is not `selfPID` and still has the
    /// recorded ``Identity`` (an ended copy, or a reused pid, even one running the same executable, is nil). Call
    /// it off the main thread.
    static func runningCopy(at url: URL, selfPID: pid_t = getpid(),
                            identity: (pid_t) -> Identity? = SingleInstanceGuard.processIdentity) -> Owner? {
        guard let data = try? Data(blockingContentsOf: url), data.count <= 64 * 1024,
              let owner = Owner(record: String(decoding: data, as: UTF8.self)), owner.pid != selfPID,
              identity(owner.pid) == owner.identity else { return nil }
        return owner
    }

    /// `pid`'s ``Identity``: its executable as LaunchServices has it registered (`NSRunningApplication`, thread
    /// safe) and its start time (``processStartTime(_:)``); nil when no running application has that pid. Never a
    /// process scan: one lookup of one recorded pid.
    static func processIdentity(_ pid: pid_t) -> Identity? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let executable = app.executableURL, let started = processStartTime(pid) else { return nil }
        return Identity(executablePath: executable.resolvingSymlinksInPath().path, started: started)
    }

    /// `pid`'s start time from the kernel (`sysctl` `KERN_PROC_PID`, one pid), `seconds.microseconds`; nil when no
    /// process has that pid.
    static func processStartTime(_ pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return "\(start.tv_sec).\(start.tv_usec)"
    }

    /// This process as the claim's owner; nil when it has no executable.
    static var currentOwner: Owner? {
        let pid = getpid()
        guard let executable = Bundle.main.executableURL, let started = processStartTime(pid) else { return nil }
        return Owner(pid: pid, bundlePath: Bundle.main.bundlePath,
                     identity: Identity(executablePath: executable.resolvingSymlinksInPath().path, started: started))
    }

    /// This launch's lock file, nil when it is not guarded.
    var lockURL: URL? {
        guard isGuarded, let bundleIdentifier else { return nil }
        return Self.lockURL(bundleIdentifier: bundleIdentifier)
    }

    /// The decision for this launch; takes the claim when this launch is guarded. The owner then records itself
    /// off the main thread for a later second copy's hand-off (``writeOwner(_:at:)``).
    func resolve() -> Decision {
        guard let lockURL else { return .launch }
        let claim = Self.claim(at: lockURL)
        if claim == .held {
            let ownerURL = Self.ownerURL(lockURL: lockURL)
            // task-owner: one write of a few bytes at launch; it ends on its own and nothing waits on it
            Task.detached(priority: .utility) {
                if let owner = Self.currentOwner { Self.writeOwner(owner, at: ownerURL) }
            }
        }
        return decide(claim)
    }
}
