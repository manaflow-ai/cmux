import Darwin
public import Foundation

/// One copy of a cmux bundle per user (field log, 2026-10-26: a NIGHTLY started by direct exec from an ssh session
/// while the first copy ran; its Chromium could not start, since the first copy holds the profile in
/// `<Application Support>/<bundle id>/Chromium`, so every restored Chromium tab loaded in WebKit, signed out).
///
/// The claim is an exclusive `flock` on `<Application Support>/<bundle id>/instance.lock`, held for the life of the
/// process (the kernel drops it when the process ends, however it ends). Two launches racing each other cannot
/// both get it. The owner writes its pid, bundle path and executable into the file (``Owner``). A copy that
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

    /// The copy that holds the claim, as it wrote itself into the lock file.
    public nonisolated struct Owner: Equatable, Sendable {
        public var pid: pid_t
        /// Its `.app` bundle: where the hand-off sends the URLs (`open -a`).
        public var bundlePath: String
        /// Its executable as the kernel reports it (`proc_pidpath`): proves `pid` is still that copy.
        public var executablePath: String

        public init(pid: pid_t, bundlePath: String, executablePath: String) {
            self.pid = pid
            self.bundlePath = bundlePath
            self.executablePath = executablePath
        }

        /// The lock file's contents: one line each for the pid, the bundle path and the executable.
        public var record: String { "\(pid)\n\(bundlePath)\n\(executablePath)\n" }

        public init?(record: String) {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 3, let pid = pid_t(lines[0]), pid > 0, !lines[1].isEmpty, !lines[2].isEmpty else { return nil }
            self.init(pid: pid, bundlePath: String(lines[1]), executablePath: String(lines[2]))
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

    /// Takes the claim at `url`, keeping the descriptor open (close-on-exec, so no child keeps it) for the life of
    /// the process, and writes `owner` into it. Only a lock another process holds is `.taken`; any file error
    /// launches as before.
    static func claim(at url: URL, owner: Owner? = nil) -> Claim {
        // blocking-allow: runs once in `main` before NSApp exists and before any other thread starts; whether this copy may start at all decides everything after it, so nothing can run first (one mkdir of an existing folder)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(fd)
            return lockError == EWOULDBLOCK ? .taken : .unavailable
        }
        if let owner {
            // A record that fails to write leaves the hand-off unresolved, so a second copy launches nothing.
            let bytes = Array(owner.record.utf8)
            _ = ftruncate(fd, 0)
            _ = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
        return .held  // fd stays open: the claim lasts until this process ends
    }

    /// The running copy holding the claim at `url`, from its record, if its pid is alive, is not `selfPID`, and
    /// still runs the recorded executable (a reused pid or a record from a copy that has ended is nil).
    static func runningCopy(at url: URL, selfPID: pid_t = getpid(),
                            executablePath: (pid_t) -> String? = SingleInstanceGuard.processExecutablePath) -> Owner? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var data: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            data += chunk[..<count]
        }
        guard let owner = Owner(record: String(decoding: data, as: UTF8.self)), owner.pid != selfPID,
              executablePath(owner.pid) == owner.executablePath else { return nil }
        return owner
    }

    /// `pid`'s executable as the kernel reports it, nil when it is not running.
    static func processExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// This process as the claim's owner; nil when it has no executable path.
    static var currentOwner: Owner? {
        let pid = getpid()
        guard let executable = processExecutablePath(pid) else { return nil }
        return Owner(pid: pid, bundlePath: Bundle.main.bundlePath, executablePath: executable)
    }

    /// This launch's lock file, nil when it is not guarded.
    var lockURL: URL? {
        guard isGuarded, let bundleIdentifier else { return nil }
        return Self.lockURL(bundleIdentifier: bundleIdentifier)
    }

    /// The decision for this launch; takes the claim when this launch is guarded.
    func resolve() -> Decision {
        guard let lockURL else { return .launch }
        return decide(Self.claim(at: lockURL, owner: Self.currentOwner))
    }
}
