public import CmuxNextTrace
public import Foundation

/// Runs a process's black-box file steps (plans/cmux-next/chrome-parity/p09-observability.md section 3A,
/// task 005) on BackgroundWork `.files`, none of them on the caller's thread:
///
/// - At once: adopt the ring file (``TraceBlackBox/adoptFile()``), so a crash after launch leaves a ring.
/// - At once, best effort: delete the black boxes of dead processes (``TraceBlackBox/cleanUp(now:)``).
/// - ``TraceBlackBox/spareDelay`` later, idle: make the next launch's spare file.
///
/// Chrome's browser does the same with its metrics file: it starts on the heap, and the file and the spare
/// are written by background tasks (components/metrics/persistent_histograms.cc).
///
/// ```swift
/// let steps = TraceBlackBoxFileSteps(blackBox: TraceBlackBox(role: .app, directory: path, runtime: .shared), work: work)
/// steps.start()
/// ```
public final class TraceBlackBoxFileSteps: Sendable {
    /// The process's ring and its file steps.
    public let blackBox: TraceBlackBox
    private let work: BackgroundWork
    /// The one deadline that makes the spare file.
    private let spare: DemandTimer

    /// Steps for `blackBox` on `work`; nothing runs until ``start()``.
    ///
    /// - Parameters:
    ///   - blackBox: The process's black box (its heap ring already records).
    ///   - work: The lanes the steps run on.
    ///   - clock: The clock of the spare file's deadline.
    public init(blackBox: TraceBlackBox, work: BackgroundWork, clock: any Clock<Duration> = ContinuousClock()) {
        self.blackBox = blackBox
        self.work = work
        spare = DemandTimer(owner: "trace.blackbox.spare", clock: clock)
    }

    /// Posts the adoption and the cleanup to `.files` and arms the spare deadline. Returns at once.
    public func start() {
        let (blackBox, work) = (blackBox, work)
        work.post(.userVisible, mayBlock: .files) { _ = blackBox.adoptFile() }
        work.post(.bestEffort, mayBlock: .files) { _ = blackBox.cleanUp() }
        spare.schedule(after: TraceBlackBox.spareDelay) {
            work.post(.idle, mayBlock: .files) { _ = blackBox.prepareSpare() }
        }
    }

    /// Starts the app process's black box: the heap ring and the black-box categories of `runtime` now,
    /// then ``start()``.
    ///
    /// - Parameters:
    ///   - bundleID: The app's bundle id; it names the folder (``appDirectory(bundleID:home:)``).
    ///   - work: The app's blocking-work lanes.
    ///   - runtime: The process's trace runtime.
    /// - Returns: The started steps; the owner keeps them so the spare deadline lives.
    public static func startApp(bundleID: String?, work: BackgroundWork, runtime: TraceRuntime = .shared) -> TraceBlackBoxFileSteps {
        let blackBox = TraceBlackBox(role: .app, directory: appDirectory(bundleID: bundleID).path, runtime: runtime,
                                     buildVersion: buildVersion(of: .main))
        let steps = TraceBlackBoxFileSteps(blackBox: blackBox, work: work)
        steps.start()
        return steps
    }

    /// The black-box folder of the app with bundle id `bundleID`: `~/Library/Logs/<bundle id>/trace`, beside
    /// its hang files (`HangEpisodeRecorder.defaultDirectory`), so each build keeps its own rings.
    public static func appDirectory(bundleID: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Logs").appending(path: bundleID ?? "com.cmuxterm.app.next").appending(path: "trace")
    }

    /// A ring header's build version from `bundle`: `<short version> (<build>)`, cut to the header's 32 bytes.
    public static func buildVersion(of bundle: Bundle) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return String(decoding: "\(version) (\(build))".utf8.prefix(32), as: UTF8.self)
    }
}
