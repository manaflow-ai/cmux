#if DEBUG || CMUX_PGO_PROFILE
import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// The profile build's two profiles from one run (p08-startup-103, plans/cmux-next/chrome-parity/p08-startup.md
/// section F): `launch.profraw` holds the counters from process start to startup complete, `rest.profraw`
/// those from then to `debug.pgo_flush` before quit. The scenario runner (050) merges both into
/// `cmux-next.profdata` and keeps the launch profile's functions for the order file (109).
///
/// At startup complete ``writeLaunchProfile(when:)`` writes the counters to the launch file, resets them and
/// names the rest file as the runtime's file, so the runtime's own write at exit lands there too.
/// ``writeRestProfile()`` writes the rest file now. Both writes are file I/O on the `.files` lane at one
/// priority, which runs one item at a time in post order: the rest write always follows the launch write,
/// the runtime's file name never changes under a write, and main never waits.
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

    /// The two files of a run.
    public struct Files: Sendable, Equatable {
        /// `launch.profraw`.
        public let launch: URL
        /// `rest.profraw`.
        public let rest: URL

        /// `launch.profraw` and `rest.profraw` in `folder`.
        public init(folder: URL) {
            launch = folder.appending(path: "launch.profraw", directoryHint: .notDirectory)
            rest = folder.appending(path: "rest.profraw", directoryHint: .notDirectory)
        }

        /// Beside the runtime's own file (`LLVM_PROFILE_FILE`, which the runner sets per run), else in
        /// `temporaryFolder`'s `cmux-pgo`. Not a `CMUX_*` variable: launch strips those when inherited.
        public init(environment: [String: String], temporaryFolder: URL) {
            guard let runtimeFile = environment["LLVM_PROFILE_FILE"], !runtimeFile.isEmpty else {
                self.init(folder: temporaryFolder.appending(path: "cmux-pgo", directoryHint: .isDirectory))
                return
            }
            self.init(folder: URL(fileURLWithPath: runtimeFile).deletingLastPathComponent())
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

    /// Why a profile was not written.
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

    /// The lane priority of both writes: one serial slot, so they run in post order.
    static let priority = WorkPriority.userVisible

    /// Where the profiles go.
    public let files: Files
    private let runtime: Runtime
    private let work: BackgroundWork
    /// Set on the lane once the launch profile is written and the counters reset.
    private let launchWritten = Atomic<Bool>(false)

    /// - Parameters:
    ///   - runtime: The profile runtime's entry points.
    ///   - files: Where the profiles go.
    ///   - work: The lanes; the writes run on `.files`.
    public init(runtime: Runtime, files: Files, work: BackgroundWork) {
        (self.runtime, self.files, self.work) = (runtime, files, work)
    }

    /// Writes the launch profile when `startup` completes (never after quit: the completion never fires then).
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
        try await withCheckedContinuation { (reply: CheckedContinuation<Result<Written, Failure>, Never>) in
            post(profile) { reply.resume(returning: $0) }
        }.get()
    }

    private func post(_ profile: Profile, _ done: @escaping @Sendable (Result<Written, Failure>) -> Void) {
        // Block shutdown: one bounded write, and a profile lost at quit is a lost scenario run.
        work.post(Self.priority, mayBlock: .files, shutdown: .blockShutdown,
                  abandoned: { done(.failure(.abandoned(profile))) }) { [self] in done(write(profile)) }
    }

    /// On the lane: the launch write switches the runtime to the rest file after the reset; the rest
    /// write needs the launch write first.
    private func write(_ profile: Profile) -> Result<Written, Failure> {
        let file = files.file(profile)
        switch profile {
        case .launch:
            do {
                try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return .failure(.folderFailed(profile))
            }
            runtime.setFile(file.path)
        case .rest:
            guard launchWritten.load(ordering: .acquiring) else { return .failure(.launchNotWritten) }
        }
        let code = runtime.write()
        guard code == 0 else { return .failure(.writeFailed(profile, code: code)) }
        if profile == .launch {
            runtime.resetCounters()
            runtime.setFile(files.rest.path)
            launchWritten.store(true, ordering: .releasing)
        }
        let bytes = (try? FileManager.checked.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard bytes > 0 else { return .failure(.empty(profile)) }
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
    /// The compiler-rt profile runtime (`InstrProfilingFile.c`). `set_filename` copies the name.
    public static var compilerRuntime: ProfileFlush.Runtime {
        ProfileFlush.Runtime(setFile: { name in name.withCString { llvmProfileSetFilename($0) } },
                             write: { llvmProfileWriteFile() }, resetCounters: { llvmProfileResetCounters() })
    }
}

// The runtime's C entry points; a profile build links them (-profile-generate, -fprofile-instr-generate).
// Each takes and returns only a pointer or an Int32, which Swift passes as C does.
@_silgen_name("__llvm_profile_write_file")
private func llvmProfileWriteFile() -> Int32

@_silgen_name("__llvm_profile_reset_counters")
private func llvmProfileResetCounters()

@_silgen_name("__llvm_profile_set_filename")
private func llvmProfileSetFilename(_ name: UnsafePointer<CChar>)
#endif
#endif
