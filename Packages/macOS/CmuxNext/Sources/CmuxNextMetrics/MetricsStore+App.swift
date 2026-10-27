public import CmuxNextCompat
public import CmuxNextTrace
public import Foundation

extension MetricsStore {
    /// Starts the app process's store: makes it, attaches it to `runtime` and adopts its file in `directory`
    /// (`metrics-app-<pid>.bin`, which the next launch folds as an earlier launch's section, task 053), all on the
    /// files lane of `work`: the profile reads two sysctls and walks the loaded images, and the build day is the
    /// executable's date. Returns at once. A runtime that has a store keeps it.
    ///
    /// Chrome makes its browser's persistent histogram allocator the same way: on the heap first, the file on a
    /// background task (components/metrics/persistent_histograms.cc, `InstantiatePersistentHistograms`).
    ///
    /// ```swift
    /// MetricsStore.startApp(directory: metricsFolder, channel: "nightly", work: work)
    /// ```
    ///
    /// - Parameters:
    ///   - directory: The launch-file folder (the hang reports' `HangReportFieldSources.appMetricsDirectory`).
    ///   - channel: The release channel the profile names.
    ///   - work: The app's blocking-work lanes.
    ///   - runtime: The process's trace runtime.
    public static func startApp(directory: URL, channel: String, work: any MayBlockRunner, runtime: TraceRuntime = .shared) {
        work.postFiles(.userVisible, shutdown: .skipOnShutdown) {
            guard MetricsStore.attached(to: runtime) == nil else { return }
            let store = MetricsStore(role: .app, profile: .current(bundle: .main, channel: channel, buildDay: MetricsStore.buildDay(of: .main)))
            guard store.attach(to: runtime) else { return }
            _ = store.adoptFile(directory: directory.path(percentEncoded: false))
        }
    }

    /// The UTC day `bundle`'s executable was written (the build's day, which decides the histograms' expiry); today
    /// when it cannot be read. Blocking file work: the files lane.
    static func buildDay(of bundle: Bundle) -> MetricsProfile.Day {
        let written = bundle.executableURL.flatMap { url in
            (try? FileManager.checked.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: written ?? Date())
        return MetricsProfile.Day(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }
}
