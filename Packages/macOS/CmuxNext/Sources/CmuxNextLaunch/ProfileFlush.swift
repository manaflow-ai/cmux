#if DEBUG || CMUX_PGO_PROFILE
import CmuxNextCompat
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceContinuation
public import Foundation
import os
#if CMUX_PGO_PROFILE
import CmuxNextProfileRuntimeC
#endif

/// The profile build's two profiles from one run (plans/cmux-next/chrome-parity/p08-startup.md
/// section F): `launch.profraw` holds the counters from process start to startup complete, `rest.profraw`
/// those from then to `debug.pgo_flush` before quit. The scenario runner (050) merges both into
/// `cmux-next.profdata` and keeps the launch profile's functions for the order file (109).
///
/// At startup complete ``writeLaunchProfile(when:)`` writes the counters to the launch file and resets them.
/// ``writeRestProfile()`` writes the rest file now. Each write names its file as the runtime's file, writes,
/// then names the exit file (``Files/exit``), whatever the outcome: the runtime's own write at exit opens
/// its file for writing, so it must never be a file this type wrote or reported. Both writes are file I/O
/// on the `.files` lane at one priority, which runs one item at a time in post order: the rest write
/// always follows the launch write, the runtime's file name never changes under a write, and main never waits.
///
/// Chrome flushes on demand with `__llvm_profile_dump` (base/test/clang_profiling.cc,
/// `WriteClangProfilingProfile`), which writes once per process and then refuses. cmux needs two files from
/// one run, so it uses `__llvm_profile_write_file` then `__llvm_profile_reset_counters`
/// (plans/cmux-next/startup-DESIGN.md section 9). The type is compiled only in Debug (for its tests) and in
/// the profile build (`CMUX_PGO_PROFILE`, `reload.sh --config profile`); Release and bench have none of it.
///
/// ```swift
/// let flush = ProfileFlush(launchedOn: work)           // profile build only: the compiler-rt runtime
/// flush.writeLaunchProfile(when: order.startup)        // launch.profraw at startup complete
/// let rest = try await flush.writeRestProfile()        // debug.pgo_flush, before quit
/// ```
public final class ProfileFlush: Sendable {
    /// Which of the two profiles.
    public enum Profile: String, Sendable {
        /// Process start to startup complete.
        case launch
        /// Startup complete to the flush before quit.
        case rest
    }

    /// The files of a run.
    public struct Files: Sendable, Equatable {
        /// `launch.profraw`.
        public let launch: URL
        /// `rest.profraw`.
        public let rest: URL
        /// The runtime's file between and after the two writes, so its write at exit goes there: a file name
        /// pattern as `LLVM_PROFILE_FILE` takes it (`%p`, `%m`). The runner's own `LLVM_PROFILE_FILE`
        /// when it set one (scripts/cmux-next/pgo/build-profile.sh checks that file), else `exit.profraw`.
        public let exit: String

        /// `launch.profraw`, `rest.profraw` and `exit.profraw` in `folder`.
        public init(folder: URL) {
            self.init(folder: folder, exit: folder.appending(path: "exit.profraw", directoryHint: .notDirectory).path)
        }

        /// Beside the runtime's own file (`LLVM_PROFILE_FILE`, which the runner sets per run), which stays the
        /// exit file; else in `temporaryFolder`'s `cmux-pgo`. Not a `CMUX_*` variable: launch strips those
        /// when inherited.
        public init(environment: [String: String], temporaryFolder: URL) {
            guard let runtimeFile = environment["LLVM_PROFILE_FILE"], !runtimeFile.isEmpty else {
                self.init(folder: temporaryFolder.appending(path: "cmux-pgo", directoryHint: .isDirectory))
                return
            }
            self.init(folder: URL(fileURLWithPath: runtimeFile).deletingLastPathComponent(), exit: runtimeFile)
        }

        private init(folder: URL, exit: String) {
            launch = folder.appending(path: "launch.profraw", directoryHint: .notDirectory)
            rest = folder.appending(path: "rest.profraw", directoryHint: .notDirectory)
            self.exit = exit
        }

        /// The file of `profile`.
        public func file(_ profile: Profile) -> URL {
            switch profile {
            case .launch: launch
            case .rest: rest
            }
        }
    }

    /// The compiler-rt profile runtime's entry points (a seam: tests pass a fake that writes a file).
    public struct Runtime: Sendable {
        /// `__llvm_profile_set_filename`: the file the next write and the write at exit go to.
        public let setFile: @Sendable (String) -> Void
        /// `__llvm_profile_write_file`: writes the counters; 0 on success.
        public let write: @Sendable () -> Int32
        /// `__llvm_profile_reset_counters`.
        public let resetCounters: @Sendable () -> Void

        public init(setFile: @escaping @Sendable (String) -> Void, write: @escaping @Sendable () -> Int32,
                    resetCounters: @escaping @Sendable () -> Void) {
            (self.setFile, self.write, self.resetCounters) = (setFile, write, resetCounters)
        }
    }

    /// One written profile.
    public struct Written: Sendable, Equatable {
        public let profile: Profile
        public let file: URL
        /// Its size on disk; more than 0.
        public let bytes: Int
    }

    /// Why a profile was not written. A rest write after a failed launch write fails with the launch's failure.
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// The rest profile was asked for before startup completed: its counters would hold the launch.
        case launchNotWritten
        /// The folder of the files could not be made.
        case folderFailed(Profile)
        /// The runtime's write returned `code`.
        case writeFailed(Profile, code: Int32)
        /// The runtime wrote an empty file.
        case empty(Profile)
        /// Shutdown dropped the write before it started.
        case abandoned(Profile)

        public var description: String {
            switch self {
            case .launchNotWritten: "the launch profile is not written yet (startup is not complete)"
            case .folderFailed(let profile): "\(profile.rawValue): its folder could not be made"
            case .writeFailed(let profile, let code): "\(profile.rawValue): __llvm_profile_write_file returned \(code)"
            case .empty(let profile): "\(profile.rawValue): the written profile is empty"
            case .abandoned(let profile): "\(profile.rawValue): shutdown dropped the write"
            }
        }
    }

    /// What the launch write left; the rest write needs `.written`.
    private enum LaunchState: Sendable {
        case pending
        case written
        case failed(Failure)
    }

    /// The lane priority of both writes: one serial slot, so they run in post order.
    static let priority = WorkPriority.userVisible
    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "startup.pgo")

    /// Where the profiles go.
    public let files: Files
    private let runtime: Runtime
    private let work: BackgroundWork
    /// Set by the launch write on the lane, or by shutdown when it drops that write.
    private let launch = Mutex(LaunchState.pending)

    /// - Parameters:
    ///   - runtime: The profile runtime's entry points.
    ///   - files: Where the profiles go.
    ///   - work: The lanes; the writes run on `.files`.
    public init(runtime: Runtime, files: Files, work: BackgroundWork) {
        (self.runtime, self.files, self.work) = (runtime, files, work)
    }

    /// Writes the launch profile when `startup` completes (never after quit: the completion never fires then).
    /// A failure is logged and kept: ``writeRestProfile()`` fails with it.
    @MainActor
    public func writeLaunchProfile(when startup: StartupScheduler) {
        startup.whenComplete { [self] _ in post(.launch) { _ in } }
    }

    /// Writes the rest profile (on the lane): `debug.pgo_flush`, before quit.
    public func writeRestProfile() async throws(Failure) -> Written {
        try await written(.rest)
    }

    /// Writes the launch profile now, as startup complete does.
    public func writeLaunchProfile() async throws(Failure) -> Written {
        try await written(.launch)
    }

    private func written(_ profile: Profile) async throws(Failure) -> Written {
        // A reply dropped without an answer is a write shutdown dropped.
        try await withOnceContinuation(failingWith: { _ in Failure.abandoned(profile) }) {
            (reply: OnceContinuation<Written, Failure>) in
            post(profile) { reply.resume(with: $0) }
        }
    }

    private func post(_ profile: Profile, _ done: @escaping @Sendable (Result<Written, Failure>) -> Void) {
        // Block shutdown: one bounded write, and a profile lost at quit is a lost scenario run.
        work.post(Self.priority, mayBlock: .files, shutdown: .blockShutdown,
                  abandoned: { [self] in done(settled(profile, .failure(.abandoned(profile)))) }) { [self] in
            done(settled(profile, write(profile)))
        }
    }

    /// Keeps a launch outcome for the rest write and logs a launch failure; returns `result`.
    private func settled(_ profile: Profile, _ result: Result<Written, Failure>) -> Result<Written, Failure> {
        guard profile == .launch else { return result }
        switch result {
        case .success:
            launch.withLock { $0 = .written }
        case .failure(let failure):
            launch.withLock { $0 = .failed(failure) }
            Self.log.error("launch profile not written: \(failure.description, privacy: .public)")
        }
        return result
    }

    /// On the lane: the launch write resets the counters after a good write; the rest write needs it first.
    private func write(_ profile: Profile) -> Result<Written, Failure> {
        switch profile {
        case .launch:
            do {
                try FileManager.checked.createDirectory(at: files.launch.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return .failure(.folderFailed(.launch))
            }
            let written = writeCounters(.launch)
            if case .success = written { runtime.resetCounters() }
            return written
        case .rest:
            switch launch.withLock({ $0 }) {
            case .pending: return .failure(.launchNotWritten)
            case .failed(let failure): return .failure(failure)
            case .written: return writeCounters(.rest)
            }
        }
    }

    /// Writes the counters to `profile`'s file and names the exit file after it; a failed or empty write
    /// leaves no file for the runner to merge.
    private func writeCounters(_ profile: Profile) -> Result<Written, Failure> {
        let file = files.file(profile)
        runtime.setFile(file.path)
        let code = runtime.write()
        runtime.setFile(files.exit)
        let bytes = code == 0 ? (try? FileManager.checked.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0 : 0
        guard bytes > 0 else {
            try? FileManager.checked.removeItem(at: file)
            return .failure(code == 0 ? .empty(profile) : .writeFailed(profile, code: code))
        }
        return .success(Written(profile: profile, file: file, bytes: bytes))
    }
}

#if CMUX_PGO_PROFILE
extension ProfileFlush {
    /// The profile build's flush: the compiler-rt runtime that `-profile-generate` links in, and the files
    /// beside `LLVM_PROFILE_FILE`.
    public convenience init(launchedOn work: BackgroundWork) {
        self.init(runtime: .compilerRuntime,
                  files: Files(environment: ProcessInfo.processInfo.environment, temporaryFolder: FileManager.default.temporaryDirectory),
                  work: work)
    }
}

extension ProfileFlush.Runtime {
    /// The compiler-rt profile runtime (`InstrProfilingFile.c`, declared in CmuxNextProfileRuntimeC).
    /// `set_filename` copies the name.
    public static var compilerRuntime: ProfileFlush.Runtime {
        ProfileFlush.Runtime(setFile: { name in __llvm_profile_set_filename(name) },
                             write: { __llvm_profile_write_file() }, resetCounters: { __llvm_profile_reset_counters() })
    }
}
#endif
#endif
