public import Foundation

/// Where the first task runs: `~/cmux/first-task`. Outside Desktop,
/// Documents and Downloads, so the agent writing there never triggers a
/// macOS privacy prompt during onboarding.
public nonisolated struct FirstTaskFolder: Sendable, Equatable {
    /// Overrides the folder (test launches).
    public static let environmentKey = "CMUX_NEXT_FIRST_TASK_DIR"
    /// The chart task's input, written into the folder.
    static let sampleName = "sales.csv"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> FirstTaskFolder {
        if let path = environment[environmentKey], !path.isEmpty { return FirstTaskFolder(url: URL(fileURLWithPath: path, isDirectory: true)) }
        return FirstTaskFolder(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: "cmux/first-task", directoryHint: .isDirectory))
    }

    /// Creates the folder; the chart task also gets the sample sheet
    /// (kept if the user already edited one).
    public func prepare(for task: FirstTask) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let sample = url.appending(path: Self.sampleName)
        if task == .chart, !FileManager.default.fileExists(atPath: sample.path) {
            try Data(Self.sampleSheet.utf8).write(to: sample, options: .atomic)
        }
    }

    /// What the task saved: every visible file but the sample, newest first.
    public func outputs() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        let dated = files.compactMap { file -> (URL, Date)? in
            guard file.lastPathComponent != Self.sampleName,
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (file, values.contentModificationDate ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// A year of monthly sales, small enough to read at a glance.
    static let sampleSheet = """
    month,revenue,orders
    Jan,12400,310
    Feb,13900,342
    Mar,15100,371
    Apr,14600,355
    May,16800,402
    Jun,18200,436
    Jul,17500,421
    Aug,19300,458
    Sep,20100,477
    Oct,21800,512
    Nov,24600,571
    Dec,27900,640

    """
}
