import CmuxNextBrowser
import Foundation
import os

/// Writes crash reports into `~/Library/Logs/cmux-next/`: one JSON file per
/// Chromium helper or renderer failure and per app crash found at launch.
/// Reports hold no typed text or page content (no URL, title or terminal
/// text): process kind, reason, code, times, the app's bundle and version,
/// and for an app crash the path of macOS's own `.ips` report.
///
/// Files are written off the main thread; the folder keeps the newest
/// `retain` reports.
nonisolated struct CrashReportWriter: Sendable {
    let directory: URL
    let bundleID: String
    let version: String
    var retain = 100

    static func standard(bundleID: String?) -> CrashReportWriter {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/cmux-next", directoryHint: .isDirectory)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = [info["CFBundleShortVersionString"] as? String, info["CFBundleVersion"] as? String]
            .compactMap { $0 }.joined(separator: " ")
        return CrashReportWriter(directory: logs, bundleID: bundleID ?? "unknown", version: version.isEmpty ? "unknown" : version)
    }

    /// The JSON object of a Chromium process failure.
    func report(for record: BrowserCrashRecord) -> [String: Any] {
        var object: [String: Any] = [
            "kind": "chromium",
            "date": Self.iso(record.date),
            "process_type": record.processType,
            "reason": record.reason.rawValue,
            "source": record.source.rawValue,
            "bundle_id": bundleID,
            "version": version,
        ]
        if let subType = record.subType { object["sub_type"] = subType }
        if let pid = record.pid { object["pid"] = Int(pid) }
        if let code = record.code { object["code"] = code }
        if let text = record.codeDescription { object["code_text"] = text }
        if let tab = record.tab { object["tab"] = tab.rawValue }
        return object
    }

    /// A report object as JSON bytes (Sendable, for the write off main).
    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// Writes `data` as `<bundle>-<name>-<timestamp>.json` and returns the
    /// file, or nil when the folder cannot be written. Call off the main
    /// thread.
    @discardableResult
    func write(_ data: Data, name: String, date: Date = Date()) -> URL? {
        let file = directory.appending(path: "\(Self.safe(bundleID))-\(Self.safe(name))-\(Self.stamp(date)).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            prune()
            return file
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "crash").error("crash report write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Writes the report of `record` on a utility queue.
    func writeInBackground(_ record: BrowserCrashRecord) {
        let data = Self.encode(report(for: record))
        let name = "chromium-\(record.processType)"
        let date = record.date
        Task.detached(priority: .utility) { self.write(data, name: name, date: date) }
    }

    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let reports = files.filter { $0.pathExtension == "json" }
        guard reports.count > retain else { return }
        let dated = reports.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(reports.count - retain) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    static func stamp(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d-%03d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0,
                      components.hour ?? 0, components.minute ?? 0, components.second ?? 0,
                      (components.nanosecond ?? 0) / 1_000_000)
    }

    static func safe(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }
}
