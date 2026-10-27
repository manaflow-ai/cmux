import CmuxNextCompat
import Foundation
@testable import CmuxNextHostPressure
import Testing

/// Linux's numbers come from /proc as acpmux reads them (cmux-tui host_pressure_probe.rs): the files
/// here are fixed text, so the parsing runs on every platform.
struct HostProcReadingsTests {
    static let meminfo = """
    MemTotal:       16318412 kB
    MemFree:          712340 kB
    MemAvailable:    1631841 kB
    Buffers:          120000 kB
    """
    static let vmstat = "nr_free_pages 178085\npswpin 12\npswpout 2560\npgfault 99\n"
    static let pressured = "some avg10=42.50 avg60=20.00 avg300=5.00 total=123456\nfull avg10=3.00 avg60=1.00 avg300=0.10 total=4567\n"
    static let calm = "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"

    private static func readings(_ files: [String: String], pageSize: UInt64 = 4096) -> ProcHostReadings {
        ProcHostReadings(read: { files[$0] }, pageSize: pageSize)
    }

    @Test func theParsersReadAcpmuxsFields() {
        #expect(ProcHostReadings.availableFraction(meminfo: Self.meminfo) == 1_631_841.0 / 16_318_412.0)
        #expect(ProcHostReadings.availableFraction(meminfo: "MemTotal: 0 kB\nMemAvailable: 10 kB\n") == nil)
        #expect(ProcHostReadings.availableFraction(meminfo: "MemTotal: 100 kB\n") == nil)
        #expect(ProcHostReadings.swappedOutPages(vmstat: Self.vmstat) == 2560)
        #expect(ProcHostReadings.swappedOutPages(vmstat: "pswpin 3\n") == nil)
        #expect(ProcHostReadings.someAvg10(psi: Self.pressured) == 42.5)
        #expect(ProcHostReadings.someAvg10(psi: "full avg10=9.00 avg60=0 avg300=0 total=0\n") == nil)
    }

    /// The sampler reads /proc through its seam: logical cores, the meminfo fraction, swap in bytes,
    /// the kernel's host name, and PSI judged against the formula's threshold.
    @Test func theSamplerReadsProc() {
        let sampler = HostSampler(readings: Self.readings([
            "/proc/meminfo": Self.meminfo,
            "/proc/vmstat": Self.vmstat,
            "/proc/pressure/memory": Self.pressured,
            "/proc/sys/kernel/hostname": "vm-360\n",
        ]))
        #expect(sampler.cores("performance").kind == "logical")
        #expect(sampler.cores("performance").count == max(1, ProcessInfo.processInfo.activeProcessorCount))
        #expect(sampler.availableRAMFraction() == 1_631_841.0 / 16_318_412.0)
        #expect(sampler.swappedOutBytes() == 2560 * 4096)
        #expect(sampler.hostName() == "vm-360")
        var formula = HostBudgetFormula()
        #expect(sampler.memoryPressure(formula: formula) == .warn)
        formula.psiSomeAvg10 = 50
        #expect(sampler.memoryPressure(formula: formula) == .normal)
    }

    #if os(Linux)
    /// The default sampler reads this host's real /proc (PSI is left out: a kernel may run without it).
    @Test func theDefaultSamplerReadsThisHostsProc() throws {
        let sampler = HostSampler()
        let fraction = try #require(sampler.availableRAMFraction())
        #expect(fraction > 0 && fraction <= 1)
        #expect(sampler.swappedOutBytes() != nil)
        #expect(!sampler.hostName().isEmpty)
        #expect(sampler.cores("performance").kind == "logical")
    }
    #endif

    @Test func unreadableFilesGiveNoNumbers() {
        let sampler = HostSampler(readings: Self.readings([:]))
        #expect(sampler.availableRAMFraction() == nil)
        #expect(sampler.swappedOutBytes() == nil)
        #expect(sampler.hostName() == "localhost")
        #expect(sampler.memoryPressure(formula: HostBudgetFormula()) == nil)
    }

    @Test func aHugeSwapCounterSaturates() {
        let readings = Self.readings(["/proc/vmstat": "pswpout \(UInt64.max / 2)\n"], pageSize: 4096)
        #expect(readings.swappedOutBytes() == .max)
    }

    /// acpmux's rule: PSI at or over the threshold is warn; PSI never reads critical.
    @Test func psiAtTheThresholdWarns() {
        #expect(HostMemoryPressure(psiSomeAvg10: 10, threshold: 10) == .warn)
        #expect(HostMemoryPressure(psiSomeAvg10: 9.99, threshold: 10) == .normal)
        #expect(HostMemoryPressure(psiSomeAvg10: 100, threshold: 10) == .warn)
    }

    @Test func theFileOverridesThePSIThreshold() throws {
        #expect(HostBudgetFormula().psiSomeAvg10 == 10)
        let json = #"{"formula": {"psi_some_avg10": 25}, "hosts": {"bad": {"psi_some_avg10": -1}}}"#
        let file = try JSONDecoder().decode(HostBudgetFile.self, from: Data(json.utf8))
        #expect(file.formula(host: "vm").psiSomeAvg10 == 25)
        #expect(file.formula(host: "bad").psiSomeAvg10 == 25)
    }

    /// With no event feed (`unknown`), the local verdict carries the PSI level; a feed's level wins.
    @Test func theLocalVerdictReadsPSIOnlyWithoutAFeed() async {
        let sampler = HostSampler(readings: Self.readings(["/proc/pressure/memory": Self.pressured]))
        let source = LocalHostPressureSource(host: "vm", sampler: sampler, acpmux: nil)
        #expect(await source.localVerdict(pressure: .unknown).pressure == .warn)
        #expect(await source.localVerdict(pressure: .normal).pressure == .normal)
        let unreadable = LocalHostPressureSource(host: "vm", sampler: HostSampler(readings: Self.readings([:])), acpmux: nil)
        #expect(await unreadable.localVerdict(pressure: .unknown).pressure == .unknown)
    }

    /// A monitor with no feed (Linux) applies the source's level as read, on the same tick as load and swap.
    @Test func aMonitorWithoutAFeedTakesTheSourcesLevel() async {
        let files = ProcFiles(["/proc/pressure/memory": Self.pressured])
        let source = LocalHostPressureSource(host: "vm", sampler: HostSampler(readings: ProcHostReadings(read: { files.read($0) }, pageSize: 4096)),
                                             acpmux: nil)
        let monitor = HostPressureMonitor(source: source, memoryPressure: nil, calmSamples: 1, ticks: false)
        await monitor.start { _, _ in }
        await monitor.read()
        #expect(await monitor.verdict?.pressure == .warn)
        #expect(await monitor.level >= .warning)
        files.set("/proc/pressure/memory", Self.calm)
        await monitor.read()
        #expect(await monitor.verdict?.pressure == .normal)
        await monitor.stop()
    }
}

/// /proc files a test changes between reads.
private final class ProcFiles: Sendable {
    private let files: Mutex<[String: String]>

    init(_ files: [String: String]) {
        self.files = Mutex(files)
    }

    func read(_ path: String) -> String? {
        files.withLock { $0[path] }
    }

    func set(_ path: String, _ text: String) {
        files.withLock { $0[path] = text }
    }
}
