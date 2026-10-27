import CmuxNextCompat
import Foundation

// oracle-input-walk (plans/cmux-next/chrome-parity/p15-oracle.md, task 105): seeded walks of the
// terminal attach machine against AttachOracle, the model-based input fuzzer of input-spec.md
// section 6 rebuilt as an executable (the 2026-10-10 ruling: not a test target, not in CI). The
// same seed gives the same walk; a failure is shrunk by delta debugging and written as its
// minimized journal. Exit 0: no violation; 1: violations (journals under --out); 2: usage.

/// Walks `options.walkCount` seeds on `options.jobs` child tasks; outcomes in seed order.
func walkAll(_ options: WalkOptions) async -> [WalkOutcome] {
    let jobs = min(options.jobs, options.walkCount)
    return await withTaskGroup(of: [WalkOutcome].self) { group in
        for job in 0..<jobs {
            group.addTask {
                stride(from: job, to: options.walkCount, by: jobs).map { index in
                    AttachWalk(seed: options.seed &+ UInt64(index), fault: options.fault)
                        .walk(steps: options.steps, shrinkBudget: options.shrinkBudget)
                }
            }
        }
        var outcomes: [WalkOutcome] = []
        for await part in group { outcomes += part }
        return outcomes.sorted { $0.seed < $1.seed }
    }
}

func standardError(_ text: String) {
    FileHandle.standardError.blockingWrite(Data((text + "\n").utf8))
}

/// Writes each failure's minimized journal under `options.out`, prints the summary line and
/// returns the exit status.
func report(_ outcomes: [WalkOutcome], options: WalkOptions) -> Int32 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var digest = JournalDigest()
    var failed: [WalkSummary.Failed] = []
    do {
        for outcome in outcomes {
            digest.add("\(outcome.seed):\(String(outcome.digest, radix: 16));")
            guard let failure = outcome.failure else { continue }
            try FileManager.checked.createDirectory(at: options.out, withIntermediateDirectories: true)
            let file = options.out.appending(path: "walk-\(failure.seed).json", directoryHint: .notDirectory)
            try encoder.encode(failure).blockingWrite(to: file, options: .atomic)
            failed.append(WalkSummary.Failed(seed: failure.seed, signature: failure.violation.signature,
                                             detail: failure.violation.detail, actions: failure.actions.count, journal: file.path))
            standardError("\(failure.violation.signature) seed \(failure.seed) (\(failure.config)): \(failure.violation.detail); "
                + "\(failure.actions.count) steps after shrinking, journal \(file.path)")
        }
        let summary = WalkSummary(seed: options.seed, fault: options.fault?.rawValue, walks: outcomes.count,
                                  stepsPerWalk: options.steps, steps: outcomes.count * options.steps,
                                  replayedWalks: outcomes.filter(\.exact).count, failures: failed.count,
                                  digest: String(digest.value, radix: 16), failed: failed)
        let line = try encoder.encode(summary)
        print(String(decoding: line, as: UTF8.self))
    } catch {
        standardError("oracle-input-walk: writing results failed: \(error)")
        return 2
    }
    return failed.isEmpty ? 0 : 1
}

let options: WalkOptions
do throws(WalkUsageError) {
    options = try WalkOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch .help {
    print(WalkOptions.usage)
    exit(0)
} catch {
    standardError("oracle-input-walk: \(error)\n\(WalkOptions.usage)")
    exit(2)
}
let outcomes = await walkAll(options)
exit(report(outcomes, options: options))
