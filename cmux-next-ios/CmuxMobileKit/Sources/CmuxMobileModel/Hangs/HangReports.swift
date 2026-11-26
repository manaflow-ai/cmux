import Darwin
import Foundation
import os
import Synchronization

/// Where hangs land: one text file per hang in the app container's `hangs/` directory
/// (`hang-<time>.txt`, at most ``limit`` files, oldest deleted first), MetricKit's hang
/// diagnostics beside them (`metrickit-<time>.json`), and the `dev.cmux.mobile` / `hangs` log.
///
/// Telemetry: the iPhone app has no remote error sink (no Sentry; `CmuxConnectivityTelemetry`
/// carries link incidents only), so a hang is reported through the unified log, the hang file
/// and MetricKit, whose `MXHangDiagnostic` Apple also collects from users who share analytics.
/// All file work runs on a utility queue, never on the main thread, and never blocks the
/// watchdog thread.
public final class HangReports: Sendable {
    public let directory: URL
    public let limit: Int
    private let queue = DispatchQueue(label: "dev.cmux.mobile.hangs", qos: .utility)
    /// The file each open hang writes to, by its start (its end rewrites the same file).
    private let names = Mutex<[UInt64: String]>([:])
    static let logger = Logger(subsystem: "dev.cmux.mobile", category: "hangs")

    public init(directory: URL = HangReports.standardDirectory, limit: Int = 20) {
        self.directory = directory
        self.limit = max(limit, 1)
    }

    /// `Library/hangs` in the app container.
    public static var standardDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("hangs", isDirectory: true)
    }

    /// Writes (or, once the hang ended, rewrites) its file. Returns at once.
    public func record(_ hang: MainThreadHangWatchdog.Hang, now: UInt64 = MainThreadHangWatchdog.now(), date: Date = Date()) {
        let name = names.withLock { names in
            if let name = names[hang.startUptimeNanos] {
                if hang.ended { names[hang.startUptimeNanos] = nil }
                return name
            }
            let started = date.addingTimeInterval(-Double(now > hang.startUptimeNanos ? now - hang.startUptimeNanos : 0) / 1e9)
            let name = "hang-\(Self.stamp(started)).txt"
            if !hang.ended { names[hang.startUptimeNanos] = name }
            return name
        }
        queue.async { [self] in
            write(name: name, contents: Data(Self.text(of: hang, date: date).utf8))
        }
    }

    /// One MetricKit diagnostic (`MXHangDiagnostic.jsonRepresentation()`).
    public func recordMetricKit(json: Data, date: Date = Date()) {
        queue.async { [self] in
            write(name: "metrickit-\(Self.stamp(date))-\(UUID().uuidString.prefix(8)).json", contents: json)
        }
    }

    /// Hang and MetricKit files, oldest first.
    public func files() -> [URL] {
        queue.sync { listing() }
    }

    /// Waits for every write queued so far (tests).
    func drain() {
        queue.sync {}
    }

    private func write(name: String, contents: Data) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            Self.logger.error("hang file \(name, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            return
        }
        let files = listing()
        for file in files.prefix(max(files.count - limit, 0)) { try? FileManager.default.removeItem(at: file) }
    }

    private func listing() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // The stamp sorts by time: the oldest come first.
        return names.filter { ($0.hasPrefix("hang-") && $0.hasSuffix(".txt")) || ($0.hasPrefix("metrickit-") && $0.hasSuffix(".json")) }
            .sorted { $0.drop { $0 != "-" } < $1.drop { $0 != "-" } }
            .map { directory.appendingPathComponent($0) }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    /// The hang file: what happened, then the symbolicated main-thread stack.
    static func text(of hang: MainThreadHangWatchdog.Hang, date: Date) -> String {
        let ms = Int((Double(hang.duration.components.seconds) * 1_000 + Double(hang.duration.components.attoseconds) / 1e15).rounded())
        var lines = [
            "cmux iPhone main-thread hang",
            "state: \(hang.ended ? "ended" : "ongoing (the app was still stuck when this was written)")",
            "duration_ms: \(ms)",
            "written: \(ISO8601DateFormatter().string(from: date))",
            "bundle: \(Bundle.main.bundleIdentifier ?? "-") \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))",
            "main thread stack (\(hang.addresses.count) frames):",
        ]
        for (index, address) in hang.addresses.enumerated() {
            lines.append("\(index) \(symbolicate(address))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `image 0xADDR symbol + offset` from dladdr (off the main thread only).
    static func symbolicate(_ address: UInt) -> String {
        let hex = "0x" + String(address, radix: 16)
        var info = Dl_info()
        guard address != 0, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return "? \(hex)" }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        guard let symbol = info.dli_sname, let base = info.dli_saddr else {
            let offset = info.dli_fbase.map { address &- UInt(bitPattern: $0) } ?? 0
            return "\(image) \(hex) + \(offset)"
        }
        return "\(image) \(hex) \(String(cString: symbol)) + \(address &- UInt(bitPattern: base))"
    }
}
