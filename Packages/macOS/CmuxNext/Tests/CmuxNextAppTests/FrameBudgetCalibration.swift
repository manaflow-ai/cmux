import Foundation

/// Frame budgets are main-thread CPU, and one runner's CPU is not another's. Not yet calibrated:
/// every budget is its nominal value on every runner.
@MainActor
struct FrameBudgetCalibration {
    var nominalMs: Double = 1
    var reference: @MainActor () -> Void = { FrameBudgetCalibration.referenceWork() }

    mutating func checkpoint() {}

    var factor: Double { 1 }
    var skipReason: String? { nil }
    func budget(_ nominal: Double) -> Double { nominal }
    var summary: String { "FRAME-BUDGET-CALIBRATION uncalibrated" }

    static var sink = 0

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
