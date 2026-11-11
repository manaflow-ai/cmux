import Foundation
import Testing

// The instant-list bench's report and its two rules (cmux-next-ios/design/instant-perf.md).
//
// Each metric is measured on the SMALL and the GOD fixture: one warm-up, then the median of
// several runs on `ContinuousClock`. It prints one `INSTANTPERF {json}` line and, when the
// environment names a file in `CMUX_INSTANT_PERF_OUT`, appends that line to it (JSONL). Under
// xcodebuild pass it as `TEST_RUNNER_CMUX_INSTANT_PERF_OUT` (the runner strips the prefix).
//
// The rules, each its own assertion:
// - budget: small and god each at most 3x the target (generous, so shared CI noise never flakes;
//   the target itself is the goal the numbers are read against);
// - ratio: god at most 1.2x small, compared as god / max(small, 1 ms). Under 1 ms nobody can
//   see a difference, and a sub-millisecond small would make any ratio noise; the floor keeps
//   "god must cost what small costs" meaningful without failing on microseconds.
// An assertion the current code fails is declared known-red for its metric: it runs under
// `withKnownIssue`, so the baseline records the red honestly and the test fails the day the code
// is fixed, until the declaration is removed.
//
// Run: swift test --package-path cmux-next-ios/CmuxMobileKit --filter CmuxMobileInstantPerfTests

enum InstantPerfCheck: String, Sendable, CaseIterable, Codable {
    case smallBudget = "small_budget"
    case godBudget = "god_budget"
    case ratio
}

struct InstantPerfResult: Codable, Sendable {
    var metric: String
    var platform: String
    var small_ms: Double
    var god_ms: Double
    /// god / max(small, `ratioFloorMs`).
    var ratio: Double
    var target_ms: Double
    var budget_ms: Double
    var ratio_limit: Double
    var small_runs: [Double]
    var god_runs: [Double]
    var known_red: [String]
    var failing: [String]
    var note: String
}

enum InstantPerfReport {
    static let ratioLimit = 1.2
    static let ratioFloorMs = 1.0
    /// Timer and scheduler noise on a shared runner: a god within this of small passes the ratio.
    /// The allowance is the larger of `noiseMs` and `noiseShareOfTarget` of the metric's target:
    /// a hosted simulator moved a 7 ms chat open by 5 to 30 ms between runs of one job
    /// (kit run 42846456096), and a tenth of the target is the bar's own "within about 10%".
    static let noiseMs: Double = 2
    static let noiseShareOfTarget: Double = 0.1
    /// A known-red check must pass at this share of its limit before its mark has to come off.
    static let clearMargin: Double = 0.75
    static let budgetFactor = 3.0

    /// Measured runs after the warm-up (`CMUX_INSTANT_PERF_RUNS` overrides).
    static var defaultRuns: Int {
        Int(ProcessInfo.processInfo.environment["CMUX_INSTANT_PERF_RUNS"] ?? "") ?? 5
    }

    static var platform: String {
        #if os(iOS)
        #if targetEnvironment(simulator)
        "ios-simulator"
        #else
        "ios"
        #endif
        #else
        "macos"
        #endif
    }

    static func ms(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// One warm-up, then `runs` samples of `body`, which returns the time it measured itself
    /// (its setup stays outside the clock).
    @MainActor
    static func sample(runs: Int = defaultRuns, _ body: () async throws -> Duration) async rethrows -> [Double] {
        _ = try await body()
        var out: [Double] = []
        for _ in 0..<max(runs, 1) { out.append(ms(try await body())) }
        return out
    }

    /// Reports the metric, then asserts its budget and ratio (known-red ones under `withKnownIssue`).
    static func record(_ metric: String, target: Double, small: [Double], god: [Double],
                       knownRed: Set<InstantPerfCheck> = [], why: String = "", note: String = "",
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let smallMs = median(small)
        let godMs = median(god)
        let budget = target * budgetFactor
        let ratio = godMs / max(smallMs, ratioFloorMs)
        let passes: [InstantPerfCheck: Bool] = [
            .smallBudget: smallMs <= budget,
            .godBudget: godMs <= budget,
            // A god that is over the ratio by less than the runner's noise is not a finding.
            .ratio: ratio <= ratioLimit || godMs - max(smallMs, ratioFloorMs) <= max(noiseMs, target * noiseShareOfTarget),
        ]
        // A known-red check has to pass with room to spare before its mark must come off; one
        // that only just passes on a quick runner stays marked, and never fails the run.
        let clearlyPasses: [InstantPerfCheck: Bool] = [
            .smallBudget: smallMs <= budget * clearMargin,
            .godBudget: godMs <= budget * clearMargin,
            .ratio: ratio <= ratioLimit * clearMargin,
        ]
        let result = InstantPerfResult(
            metric: metric, platform: platform, small_ms: rounded3(smallMs), god_ms: rounded3(godMs), ratio: rounded3(ratio),
            target_ms: target, budget_ms: budget, ratio_limit: ratioLimit,
            small_runs: small.map(rounded3), god_runs: god.map(rounded3),
            known_red: InstantPerfCheck.allCases.filter(knownRed.contains).map(\.rawValue),
            failing: InstantPerfCheck.allCases.filter { passes[$0] == false }.map(\.rawValue),
            note: note)
        emit(result)

        for check in InstantPerfCheck.allCases {
            let ok = passes[check] ?? false
            let comment: Comment = switch check {
            case .smallBudget: "\(metric): small \(fmt(smallMs)) ms over the \(fmt(budget)) ms budget (3x the \(fmt(target)) ms target)"
            case .godBudget: "\(metric): god \(fmt(godMs)) ms over the \(fmt(budget)) ms budget (3x the \(fmt(target)) ms target)"
            case .ratio: "\(metric): god \(fmt(godMs)) ms is \(fmt(ratio))x small \(fmt(smallMs)) ms (floor \(fmt(ratioFloorMs)) ms); the rule is at most \(fmt(ratioLimit))x"
            }
            if knownRed.contains(check) {
                withKnownIssue("\(metric) \(check.rawValue) is red on base (\(why)); tracked in plans/feat-ios-instant-list/DESIGN.md (cmuxterm-hq). Remove it from knownRed once fixed.",
                               isIntermittent: clearlyPasses[check] != true) {
                    #expect(ok, comment, sourceLocation: sourceLocation)
                }
            } else {
                #expect(ok, comment, sourceLocation: sourceLocation)
            }
        }
    }

    private static func rounded3(_ value: Double) -> Double { (value * 1_000).rounded() / 1_000 }
    private static func fmt(_ value: Double) -> String { String(format: "%.3f", value) }

    private static let lock = NSLock()

    static func emit(_ result: InstantPerfResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(result), let text = String(data: json, encoding: .utf8) else { return }
        let line = "INSTANTPERF \(text)"
        print(line)
        guard let path = ProcessInfo.processInfo.environment["CMUX_INSTANT_PERF_OUT"], !path.isEmpty else { return }
        lock.withLock {
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                print("INSTANTPERF could not open \(path)")
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((text + "\n").utf8))
        }
    }
}
