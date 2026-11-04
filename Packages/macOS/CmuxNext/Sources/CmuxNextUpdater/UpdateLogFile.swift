import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// The updater's trace on disk, `~/Library/Logs/cmux-next/<bundle>-updater.log`: every
/// ``UpdateLogBuffer`` line with its time and process id, so an update that relaunched cmux can be
/// traced after the fact (the check, which path installed it, the relaunch, the next launch's build).
/// Unified logging kept none of a nightly's updater lines on Leo's Mac (ask-8112d98df7, 2026-11-04:
/// "i only clicked the download button and it allegedly updated but i didnt restart the app").
///
/// Lines are written in order on one files lane of ``BackgroundWork`` (one priority, so one serial
/// queue), never on the caller's thread. The lines just before an install's quit matter most, and
/// Sparkle's quit does not wait for the lane, so they run at ``WorkPriority/userVisible`` (written
/// within milliseconds, well before the quit's own steps end) and are marked
/// ``ShutdownBehavior/blockShutdown`` for any quit that does drain the lanes. Past ``rotateBytes``
/// the file moves to `<name>.1`, replacing the older one, so the two stay under twice that.
nonisolated public struct UpdateLogFile: Sendable {
    /// The log file.
    public let url: URL
    private let work: BackgroundWork

    /// The size past which the file moves to `<name>.1` before the next line.
    static let rotateBytes: UInt64 = 1 << 20

    public init(url: URL, work: BackgroundWork) {
        self.url = url
        self.work = work
    }

    /// `~/Library/Logs/cmux-next/<bundle>-updater.log`, beside the crash reports; nil in a test
    /// process (`swift test` and XCTest hosts), so no test writes to the person's logs.
    public static func app(bundleIdentifier: String, work: BackgroundWork,
                           process: ProcessInfo = .processInfo) -> UpdateLogFile? {
        guard !isTestProcess(name: process.processName, environment: process.environment) else { return nil }
        let bundle = String(bundleIdentifier.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/cmux-next", directoryHint: .isDirectory)
        return UpdateLogFile(url: logs.appending(path: "\(bundle)-updater.log"), work: work)
    }

    /// `swift test` runs Swift Testing in `swiftpm-testing-helper` and XCTest in `xctest`; an app
    /// test host has the XCTest variables (as `AcpmuxEnvironment.isTestProcess`).
    static func isTestProcess(name: String, environment: [String: String]) -> Bool {
        ["swiftpm-testing-helper", "xctest"].contains(name)
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains { environment[$0] != nil }
    }

    /// One line, `<ISO 8601 time> [<pid>] <message>`, stamped now and appended after every earlier one.
    public func write(_ message: String, at date: Date = Date()) {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        let line = Data("\(stamp) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n".utf8)
        let url = url
        work.post(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { Self.append(line, to: url) }
    }

    /// Appends `line` to `url`, rotating first when the file is past ``rotateBytes``. A failure drops
    /// the line: the in-memory buffer and unified logging still have it.
    static func append(_ line: Data, to url: URL) {
        let files = FileManager.checked
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? files.attributesOfItem(atPath: url.path)[.size] as? UInt64, size >= rotateBytes {
                let old = url.appendingPathExtension("1")
                try? files.removeItem(at: old)
                try files.moveItem(at: url, to: old)
            }
            if !files.fileExists(atPath: url.path) { _ = files.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.blockingWrite(contentsOf: line)
        } catch {
            return
        }
    }
}
