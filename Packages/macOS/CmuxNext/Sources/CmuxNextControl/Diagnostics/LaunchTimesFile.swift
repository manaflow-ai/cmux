import CmuxNextCompat
public import CmuxNextWakeups
import Darwin
public import Foundation
import os

/// Writes this launch's ``LaunchTimesRecord`` once, off the main thread (CMUX-571). The app's composition
/// root makes one per launch and calls ``write(marks:)`` when the first window frame and Home's reveal are
/// both marked; the write also logs the line at `.notice`, which a release build keeps.
public nonisolated struct LaunchTimesRecorder: Sendable {
    /// When this process started (`sysctl` `KERN_PROC_PID`): the launch marks' zero.
    public static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    let file: LaunchTimesFile
    let work: BackgroundWork
    let version: String, build: String, commit: String?
    /// Whether the updater pre-warmed `build` before this launch (consumes its marker). Blocking.
    let prewarmed: @Sendable (_ build: String) -> Bool

    /// - Parameter info: the bundle's Info.plist (`CFBundleShortVersionString`, `CFBundleVersion`, `CMUXCommit`).
    public init(file: LaunchTimesFile, work: BackgroundWork, info: [String: Any], prewarmed: @escaping @Sendable (_ build: String) -> Bool) {
        self.file = file
        self.work = work
        version = info["CFBundleShortVersionString"] as? String ?? ""
        build = info["CFBundleVersion"] as? String ?? ""
        commit = info["CMUXCommit"] as? String
        self.prewarmed = prewarmed
    }

    /// Appends the record of a launch with `marks` (milliseconds since ``processStart``) on a files lane.
    public func write(marks: [String: Double]) {
        let recorder = self
        work.post(.bestEffort, mayBlock: .files) {
            let record = LaunchTimesRecord(marks: marks, startedAt: Self.processStart, version: recorder.version, build: recorder.build,
                                           commit: recorder.commit, prewarmed: recorder.prewarmed(recorder.build))
            let log = Logger(subsystem: "com.cmuxterm.app.next", category: "launch")
            do {
                let line = try recorder.file.append(record)
                log.notice("launch-times \(line, privacy: .public)")
            } catch {
                log.error("launch-times not written: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// One launch's times, as `cmux app launch-times` prints them (CMUX-571). Every build writes it,
/// release and NIGHTLY included: the launch marks themselves live only in memory and `debug.timings`
/// answers only in a debug build, so a release launch was unmeasurable after the fact.
///
/// The milliseconds are on the launch marks' clock (since the process started, `DebugTimings`).
public nonisolated struct LaunchTimesRecord: Codable, Equatable, Sendable {
    /// When the process started (ISO 8601, UTC).
    public var startedAt: String
    /// `CFBundleShortVersionString`.
    public var version: String
    /// `CFBundleVersion`.
    public var build: String
    /// `CMUXCommit`; nil in a build that has none.
    public var commit: String?
    /// Process start to `main` (`main_start`): exec, dyld, static initializers.
    public var preMainMs: Double?
    /// `main` to the first window frame committed.
    public var mainMs: Double?
    /// Process start to the first window frame committed (`first_window_frame_committed`).
    public var firstWindowFrameMs: Double?
    /// Process start to Home's first page on screen: its page in its dock, drawn from its saved state
    /// (`home.saved_page_shown`), else the Chief's first page (`home.first_page`, classic Home); nil when
    /// Home showed by its deadline first.
    public var homeFirstPageMs: Double?
    /// What showed Home: `mark` (its first page came) or `deadline` (``LaunchReveal``'s deadline passed first).
    public var homeRevealedBy: String?
    /// The updater pre-warmed this build before this launch (`StagedUpdatePrewarm`): this is the first
    /// launch of a build the running app ran once while the update waited.
    public var prewarmed: Bool
    /// The launch before this one (in the file) was another build or there was none: the first launch of
    /// this bundle's build, so likely the first exec of its files.
    public var firstLaunchOfBuild: Bool

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at", version, build, commit
        case preMainMs = "pre_main_ms", mainMs = "main_ms", firstWindowFrameMs = "first_window_frame_ms"
        case homeFirstPageMs = "home_first_page_ms", homeRevealedBy = "home_revealed_by"
        case prewarmed, firstLaunchOfBuild = "first_launch_of_build"
    }

    /// The record of a launch whose marks are `marks` (name to milliseconds since process start).
    /// ``firstLaunchOfBuild`` is set by ``LaunchTimesFile/append(_:)``, which knows the launch before.
    public init(marks: [String: Double], startedAt: Date, version: String, build: String, commit: String?, prewarmed: Bool) {
        func round(_ ms: Double?) -> Double? { ms.map { ($0 * 10).rounded() / 10 } }
        self.startedAt = startedAt.formatted(.iso8601)
        self.version = version
        self.build = build
        self.commit = commit
        preMainMs = round(marks["main_start"])
        firstWindowFrameMs = round(marks["first_window_frame_committed"])
        if let main = marks["main_start"], let frame = marks["first_window_frame_committed"] { mainMs = round(frame - main) }
        homeFirstPageMs = round(marks["home.saved_page_shown"] ?? marks["home.first_page"])
        if marks["reveal.home"] != nil { homeRevealedBy = marks["reveal.home.by_deadline"] != nil ? "deadline" : "mark" }
        self.prewarmed = prewarmed
        firstLaunchOfBuild = true
    }

    /// The marks the record waits for before it is written: the first window frame and Home's reveal.
    public static let awaitedMarks = ["first_window_frame_committed", "reveal.home"]
}

/// `~/Library/Application Support/<bundle id>/launch-times.jsonl`: one ``LaunchTimesRecord`` per
/// line, the last ``capacity`` launches, oldest first. Each append rewrites the file (atomically)
/// with at most ``capacity`` lines, so it never grows; a file past ``maximumBytes`` (not one this
/// writes) is started over. Blocking: call it on a files lane.
public nonisolated struct LaunchTimesFile: Sendable {
    public static let fileName = "launch-times.jsonl"
    /// The launches kept.
    public static let capacity = 50
    /// Larger than `capacity` records can be: anything bigger is not this file's and is not read.
    static let maximumBytes = 256 * 1024

    public let url: URL
    public let capacity: Int

    public init(url: URL, capacity: Int = LaunchTimesFile.capacity) {
        self.url = url
        self.capacity = max(1, capacity)
    }

    /// `<bundle id>`'s folder of Application Support.
    public static func supportDirectory(bundleID: String) -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: bundleID, directoryHint: .isDirectory)
    }

    /// The app's file; nil in a test process (`swift test`, XCTest hosts), so no test writes the person's file.
    public static func app(bundleID: String, process: ProcessInfo = .processInfo) -> LaunchTimesFile? {
        let environment = process.environment
        if ["swiftpm-testing-helper", "xctest"].contains(process.processName)
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains(where: environment.keys.contains) {
            return nil
        }
        return LaunchTimesFile(url: supportDirectory(bundleID: bundleID).appending(path: fileName))
    }

    /// The records in the file, oldest first; lines that do not parse are skipped.
    public func records() -> [LaunchTimesRecord] {
        lines().compactMap { try? JSONDecoder().decode(LaunchTimesRecord.self, from: Data($0.utf8)) }
    }

    /// Appends `record`, keeping the last ``capacity`` lines. Sets its ``LaunchTimesRecord/firstLaunchOfBuild``
    /// from the launch before. Returns the line written.
    @discardableResult
    public func append(_ record: LaunchTimesRecord) throws -> String {
        var record = record
        let earlier = lines()
        if let last = earlier.last.flatMap({ try? JSONDecoder().decode(LaunchTimesRecord.self, from: Data($0.utf8)) }) {
            record.firstLaunchOfBuild = last.version != record.version || last.build != record.build || last.commit != record.commit
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = String(decoding: try encoder.encode(record), as: UTF8.self)
        let kept = earlier.suffix(capacity - 1) + [line]
        try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((kept.joined(separator: "\n") + "\n").utf8).blockingWrite(to: url, options: .atomic)
        return line
    }

    private func lines() -> [String] {
        guard let data = try? Data(blockingContentsOf: url), data.count <= Self.maximumBytes else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
