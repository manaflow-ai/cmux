import Darwin
public import Foundation

/// One copy of a cmux bundle per user (field log, 2026-10-26: a NIGHTLY started by direct exec from an ssh session
/// while the first copy ran; its Chromium could not start, since the first copy holds the profile in
/// `<Application Support>/<bundle id>/Chromium`, so every restored Chromium tab loaded in WebKit, signed out).
///
/// The claim is an exclusive `flock` on `<Application Support>/<bundle id>/instance.lock`, held for the life of the
/// process (the kernel drops it when the process ends, however it ends). Two launches racing each other cannot
/// both get it. A copy that cannot get it hands its URLs and files to the owner and exits
/// (`SingleInstanceHandoff`), before it reads the relaunch-focus record, a session, the daemon or CEF.
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

public extension SingleInstanceGuard {
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

    /// This launch's lock file, nil when it is not guarded.
    var lockURL: URL? {
        guard isGuarded, let bundleIdentifier else { return nil }
        return Self.lockURL(bundleIdentifier: bundleIdentifier)
    }

    /// The decision for this launch; takes the claim when this launch is guarded.
    func resolve() -> Decision {
        guard let lockURL else { return .launch }
        return decide(Self.claim(at: lockURL))
    }
}
