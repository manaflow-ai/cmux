import CmuxNextUpdater
import Darwin
import Foundation

/// One copy of a cmux bundle per user (field log, 2026-10-26: a NIGHTLY started by direct exec from an ssh session
/// while the first copy ran; its Chromium could not start, since the first copy holds the profile in
/// `<Application Support>/<bundle id>/Chromium`, so every restored Chromium tab loaded in WebKit, signed out).
///
/// The claim is an exclusive `flock` on `<Application Support>/<bundle id>/instance.lock`, held for the life of the
/// process (the kernel drops it when the process ends, however it ends) and holding the owner's pid. Two launches
/// racing each other cannot both get it. A copy that cannot get it hands its URLs and files to the owner and exits
/// (`SingleInstanceHandoff`), before it reads the relaunch-focus record, a session, the daemon or CEF.
/// `LSMultipleInstancesProhibited` is not used: it does nothing for a direct exec (the copy above).
///
/// Not guarded: DEV and staging bundles (harnesses run a tagged bundle beside another copy of it; their own bundle
/// ids keep their data apart) and a launch with `CMUX_NEXT_ALLOW_SECOND_INSTANCE=1`. DEV, NIGHTLY and stable have
/// different bundle ids, so different locks. Sparkle's relaunch starts the new build only after the old process
/// exited (its installer waits on the old pid), so the lock is free by then.
nonisolated struct SingleInstanceGuard: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        /// Start normally (this process owns the claim, or is not guarded).
        case launch
        /// Another copy owns the claim: forward to `owner` and exit. `activates` is false for an agent launch
        /// (`CMUX_NEXT_NO_ACTIVATE=1`), which then forwards nothing (an open would bring the owner forward).
        case handOff(owner: pid_t, activates: Bool)
    }

    /// The outcome of trying to take the claim.
    enum Claim: Equatable, Sendable {
        /// This process holds it.
        case held
        /// Another live process holds it; `owner` is its pid when it was recorded.
        case taken(owner: pid_t?)
        /// No claim could be tried (no Application Support directory, a file error): launch as before.
        case unavailable
    }

    static let allowKey = "CMUX_NEXT_ALLOW_SECOND_INSTANCE"

    var bundleIdentifier: String?
    var environment: [String: String]

    /// Whether this launch takes part in the claim at all.
    var isGuarded: Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return !UpdateTrack.isDevelopmentBundle(bundleIdentifier) && environment[Self.allowKey] != "1"
    }

    /// The decision for this launch given the claim's outcome. A taken claim whose owner never recorded its pid
    /// launches: there is no one to hand to, and refusing would lose the launch.
    func decide(_ claim: Claim) -> Decision {
        guard isGuarded, case .taken(let owner?) = claim, owner > 0, owner != getpid() else { return .launch }
        return .handOff(owner: owner, activates: environment["CMUX_NEXT_NO_ACTIVATE"] != "1")
    }
}

extension SingleInstanceGuard {
    /// This process.
    static var current: SingleInstanceGuard {
        SingleInstanceGuard(bundleIdentifier: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment)
    }

    /// The lock file of `bundleIdentifier`.
    static func lockURL(bundleIdentifier: String,
                        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first) -> URL? {
        applicationSupport?.appending(path: bundleIdentifier).appending(path: "instance.lock")
    }

    /// Takes the claim at `url`, keeping the descriptor open (close-on-exec) for the life of the process. A taken
    /// lock's owner pid is read back for up to `ownerWait` microseconds (the owner writes it right after it locks).
    static func claim(at url: URL, ownerWait: useconds_t = 500_000) -> Claim {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            let pid = Data("\(getpid())\n".utf8)
            _ = ftruncate(fd, 0)
            _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
            return .held  // fd stays open: the claim lasts until this process ends
        }
        let lockError = errno
        defer { close(fd) }
        guard lockError == EWOULDBLOCK else { return .unavailable }
        var waited: useconds_t = 0
        while true {
            if let owner = ownerPID(fd) { return .taken(owner: owner) }
            guard waited < ownerWait else { return .taken(owner: nil) }
            usleep(25_000)
            waited += 25_000
        }
    }

    private static func ownerPID(_ fd: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    /// The decision for this launch; takes the claim when this launch is guarded.
    func resolve() -> Decision {
        guard isGuarded, let bundleIdentifier, let url = Self.lockURL(bundleIdentifier: bundleIdentifier) else { return .launch }
        return decide(Self.claim(at: url))
    }
}
