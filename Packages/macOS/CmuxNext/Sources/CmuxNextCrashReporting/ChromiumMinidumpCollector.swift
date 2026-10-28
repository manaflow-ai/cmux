public import CmuxNextWakeups
public import Foundation

/// Collects the Chromium Host's Crashpad dumps (p01-process task 226): reads the dumps written since
/// the last scan off the main thread (``ChromiumCrashpadDatabase``), names their frames
/// (``ChromiumMinidumpSymbolizer``), keeps the newest for `debug.crashes`, and hands each to the app,
/// which writes it into its crash report folder.
///
/// Each report also goes to `send`: ``CrashReporter/sendChromiumDump(_:)``, which sends a helper's
/// dump to Sentry under the same consent as the app's own crashes.
///
/// The app scans at each Chromium start and after each Chromium process end: Crashpad has written the
/// dump before a crashed process ends, so a scan after the end finds it. Scans never overlap; one
/// asked for during a scan runs after it.
@MainActor
public final class ChromiumMinidumpCollector {
    /// How many reports ``reports`` keeps.
    public static let capacity = 16

    /// The newest reports, oldest first.
    public private(set) var reports: [ChromiumMinidumpReport] = []
    /// Reports since launch (``reports`` keeps only ``capacity``).
    public private(set) var total = 0

    private let database: ChromiumCrashpadDatabase
    private let symbolizer: ChromiumMinidumpSymbolizer
    private let send: (@Sendable (ChromiumMinidumpReport) -> Void)?
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    private let onReport: @MainActor (ChromiumMinidumpReport) -> Void
    private var scanning = false
    private var scanAgain = false

    /// - Parameters:
    ///   - database: The host's Crashpad database.
    ///   - symbolizer: Names the frames.
    ///   - send: Gets each report off the main thread (``CrashReporter/sendChromiumDump(_:)``).
    ///   - work: Runs the reads on its files lane.
    ///   - mainWork: Where each scan's reports arrive.
    ///   - onReport: Runs on main for each new report.
    public init(database: ChromiumCrashpadDatabase, symbolizer: ChromiumMinidumpSymbolizer = ChromiumMinidumpSymbolizer(),
                send: (@Sendable (ChromiumMinidumpReport) -> Void)?, work: BackgroundWork, mainWork: MainWorkScheduler,
                onReport: @escaping @MainActor (ChromiumMinidumpReport) -> Void = { _ in }) {
        self.database = database
        self.symbolizer = symbolizer
        self.send = send
        self.work = work
        self.mainWork = mainWork
        self.onReport = onReport
    }

    /// Reads the dumps written since the last scan, off the main thread.
    public func scan() {
        guard !scanning else {
            scanAgain = true
            return
        }
        scanning = true
        let (database, symbolizer, send, work, mainWork) = (database, symbolizer, send, work, mainWork)
        work.task(.bestEffort) { [weak self] in
            let found = await Self.collect(database: database, symbolizer: symbolizer, send: send, work: work)
            mainWork.postFromAnyThread(.background, owner: "ChromiumMinidumpCollector.scan") { [weak self] in
                self?.collected(found)
            }
        }
    }

    /// The new dumps, read on the files lane and symbolicated, each passed to `send`.
    @concurrent nonisolated static func collect(database: ChromiumCrashpadDatabase, symbolizer: ChromiumMinidumpSymbolizer,
                                                send: (@Sendable (ChromiumMinidumpReport) -> Void)?,
                                                work: BackgroundWork) async -> [ChromiumMinidumpReport] {
        let read: [Found]
        do {
            read = try await work.run(.bestEffort, mayBlock: .files) {
                database.takeNew().map { Found(report: $0, jobs: symbolizer.jobs(for: $0)) }
            }
        } catch {
            return []  // shutdown dropped the read: the dumps stay unseen for the next launch
        }
        var reports: [ChromiumMinidumpReport] = []
        for found in read {
            var report = found.report
            report.symbols = await symbolizer.symbols(for: report, jobs: found.jobs)
            send?(report)
            reports.append(report)
        }
        return reports
    }

    /// A dump read on the files lane and the `atos` runs that name its frames.
    nonisolated struct Found: Sendable {
        var report: ChromiumMinidumpReport
        var jobs: [ChromiumMinidumpSymbolizer.Job]
    }

    private func collected(_ found: [ChromiumMinidumpReport]) {
        scanning = false
        total += found.count
        reports.append(contentsOf: found)
        if reports.count > Self.capacity { reports.removeFirst(reports.count - Self.capacity) }
        for report in found { onReport(report) }
        if scanAgain {
            scanAgain = false
            scan()
        }
    }
}
