import Foundation

/// Frame budgets are main-thread CPU, and one runner's CPU is not another's: on aws-m4pro-9 every
/// sidebar scroll frame, its commit included, took 3-4x its CPU on aws-m4pro-6 (a quiet 500-row
/// p50 of 4.06 ms against 0.90 ms), and a budget set on the fast host failed on the slow one with
/// no change in the code. A run times a fixed reference workload on its own main thread, on the
/// clock and at the size of a frame, before its frames and between them (`checkpoint()`), and
/// scales its budgets by how much slower than nominal the slowest checkpoint ran. A fast runner
/// never tightens a budget (the factor is at least 1). A runner too slow for its frames to say much
/// about the code (over `maxFactor`), or too noisy to read, skips the budgets: the suite prints the
/// reason and checks nothing timed, rather than passing them.
@MainActor
struct FrameBudgetCalibration {
    /// Main-thread CPU of one `referenceWork()`, ms, on the hosts the frame budgets were set on: a
    /// fact about the workload, not about the runner a test is on. Measured 1.74 ms on aws-m4pro-5
    /// (2026-10-21, a 500-row quiet scroll p50 of 0.65 ms there), rounded up so a host that fast
    /// keeps a factor of 1.
    static let nominalReferenceMs = 2.0
    /// Past this the budgets are skipped, not scaled: a frame budget more than this many times its
    /// nominal value no longer tells a slow runner from slow code.
    static let maxFactor = 4.0
    /// Reference samples are too noisy to scale by when, inside a checkpoint, their p90 is more than
    /// this times their p10, or the slowest checkpoint's median is more than this times the fastest's.
    static let maxSpread = 2.0
    static let samplesPerCheckpoint = 15

    let nominalMs: Double
    /// The reference workload (`referenceWork()`; a test stands in a slowed one).
    let reference: @MainActor () -> Void
    /// Each checkpoint's samples, ms.
    private(set) var checkpoints: [[Double]] = []

    init(nominalMs: Double = FrameBudgetCalibration.nominalReferenceMs,
         reference: @escaping @MainActor () -> Void = { FrameBudgetCalibration.referenceWork() }) {
        self.nominalMs = nominalMs
        self.reference = reference
    }

    /// Times the reference workload `samplesPerCheckpoint` times, after one warm-up run.
    mutating func checkpoint() {
        let work = self.reference
        work()
        let samples = (0..<Self.samplesPerCheckpoint).map { _ in Self.cpuMs { work() } }
        checkpoints.append(samples)
    }

    private var medians: [Double] { checkpoints.map { SidebarScrollBench.percentile($0, 0.5) } }

    /// The slowest checkpoint's median over nominal, at least 1.
    var factor: Double { max(1, (medians.max() ?? nominalMs) / nominalMs) }

    /// Why this run's timings cannot be held to a budget, or nil when they can.
    var skipReason: String? {
        guard !checkpoints.isEmpty else { return "the reference workload was never timed" }
        let raw = (medians.max() ?? 0) / nominalMs
        if raw > Self.maxFactor {
            return String(format: "the runner ran the reference workload %.2fx slower than nominal (over %.1fx)", raw, Self.maxFactor)
        }
        for (index, samples) in checkpoints.enumerated() {
            let p10 = SidebarScrollBench.percentile(samples, 0.1), p90 = SidebarScrollBench.percentile(samples, 0.9)
            if p90 > p10 * Self.maxSpread {
                return String(format: "reference samples at checkpoint %d spread p10 %.3f ms to p90 %.3f ms (over %.1fx)", index, p10, p90, Self.maxSpread)
            }
        }
        if let low = medians.min(), let high = medians.max(), high > low * Self.maxSpread {
            return String(format: "the runner's speed changed during the run: checkpoint medians %.3f to %.3f ms (over %.1fx)", low, high, Self.maxSpread)
        }
        return nil
    }

    /// `nominal` ms of budget, scaled to this runner.
    func budget(_ nominal: Double) -> Double { nominal * factor }

    var summary: String {
        let list = medians.map { String(format: "%.3f", $0) }.joined(separator: " ")
        return String(format: "FRAME-BUDGET-CALIBRATION nominal %.3f ms | checkpoint medians ms ", nominalMs) + list
            + String(format: " | factor %.2f | ", factor) + (skipReason.map { "skip: " + $0 } ?? "scaled")
    }

    /// Keeps `referenceWork()`'s result alive, so the optimizer cannot drop the work.
    static var sink = 0

    /// A fixed, deterministic piece of main-thread work shaped like a frame's: strings formatted,
    /// hashed into a dictionary, sorted and walked, a frame or two's worth of it.
    static func referenceWork() {
        var words: [String] = []
        words.reserveCapacity(1_000)
        for i in 0..<1_000 { words.append("row \((i &* 2_654_435_761) % 997) status line \(i)") }
        var lengths: [String: Int] = [:]
        for word in words { lengths[word, default: 0] += word.utf8.count }
        words.sort()
        var hash = 0
        for word in words { hash = hash &* 31 &+ (lengths[word] ?? 0) }
        sink &+= hash
    }

    /// Main-thread CPU of `work`, ms, on the clock SidebarScrollBench times frames with.
    static func cpuMs(_ work: () -> Void) -> Double {
        let started = SidebarScrollBench.threadCPU()
        work()
        return (SidebarScrollBench.threadCPU() - started) * 1_000
    }
}
