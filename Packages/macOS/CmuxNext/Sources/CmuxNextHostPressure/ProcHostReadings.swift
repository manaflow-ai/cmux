import CmuxNextCompat
import Foundation

/// Linux's host numbers from /proc, read and parsed as acpmux does (cmux-tui
/// host_pressure_probe.rs) and as Chromium parses /proc/meminfo and /proc/vmstat
/// (base/process/process_metrics_linux.cc, `ParseProcMeminfo`, `ParseProcVmstat`):
/// available RAM is MemAvailable / MemTotal, swap-outs are `pswpout` pages, memory
/// pressure is PSI's `some avg10` (/proc/pressure/memory). Linux has no perf levels
/// and acpmux counts no physical cores there, so the budget counts logical CPUs.
///
/// `read` returns a file's text, nil when it is unreadable: ``readProcFile(_:)`` in
/// the app, fixed text in tests. The type has no platform code, so its parsing is
/// tested on every platform.
struct ProcHostReadings: HostReadings {
    typealias ReadFile = @Sendable (_ path: String) -> String?

    private let read: ReadFile
    private let pageSize: UInt64

    init(read: @escaping ReadFile, pageSize: UInt64 = UInt64(getpagesize())) {
        self.read = read
        self.pageSize = pageSize
    }

    /// Reads one /proc file through the checked blocking seam (an in-memory kernel file).
    static func readProcFile(_ path: String) -> String? {
        try? String(blockingContentsOfFile: path, encoding: .utf8)
    }

    func performanceCores() -> Int? {
        nil
    }

    func physicalCores() -> Int? {
        nil
    }

    func availableRAMFraction() -> Double? {
        read("/proc/meminfo").flatMap(Self.availableFraction(meminfo:))
    }

    func hostName() -> String? {
        let name = read("/proc/sys/kernel/hostname")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    func swappedOutBytes() -> UInt64? {
        guard let pages = read("/proc/vmstat").flatMap(Self.swappedOutPages(vmstat:)) else { return nil }
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? .max : bytes
    }

    func memoryPressure(psiThreshold: Double) -> HostMemoryPressure? {
        read("/proc/pressure/memory").flatMap(Self.someAvg10(psi:)).map { HostMemoryPressure(psiSomeAvg10: $0, threshold: psiThreshold) }
    }

    /// MemAvailable / MemTotal from /proc/meminfo; nil without either line or with a zero total.
    static func availableFraction(meminfo: String) -> Double? {
        func kilobytes(_ key: String) -> Double? {
            for line in meminfo.split(separator: "\n") where line.hasPrefix(key) {
                let value = line.dropFirst(key.count).split(separator: " ").first
                return value.flatMap { Double($0) }
            }
            return nil
        }
        guard let total = kilobytes("MemTotal:"), total > 0, let available = kilobytes("MemAvailable:") else { return nil }
        return available / total
    }

    /// The pages swapped out since boot (`pswpout`) from /proc/vmstat.
    static func swappedOutPages(vmstat: String) -> UInt64? {
        for line in vmstat.split(separator: "\n") where line.hasPrefix("pswpout ") {
            return UInt64(line.dropFirst("pswpout ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// `some avg10` from /proc/pressure/memory (`some avg10=1.23 avg60=... total=...`): the share of
    /// the last 10 s in which at least one task waited for memory, in percent.
    static func someAvg10(psi: String) -> Double? {
        guard let some = psi.split(separator: "\n").first(where: { $0.hasPrefix("some ") }) else { return nil }
        for field in some.split(separator: " ") where field.hasPrefix("avg10=") {
            return Double(field.dropFirst("avg10=".count))
        }
        return nil
    }
}
