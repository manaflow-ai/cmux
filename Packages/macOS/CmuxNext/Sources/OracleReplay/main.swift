// OracleReplay (`oracle-replay`, plans/cmux-next/chrome-parity/p15-oracle.md task 104): saved input journals
// replayed against the pure reducers in CmuxNextInputModel, the offline form of `debug.replay`
// (plans/cmux-next/input-spec.md section 5). Each journal goes through `InputReplay(entries).run()`, the call
// `debug.replay` makes, so `--replay-json` prints the method's result for the same entries.
//
// The journals come from the oracle's corpus runs: driver_app.py saves the app's journal at the end of each case
// as `<run out>/journals/<suite>/<case>.jsonl`, and tests/oracle/corpus/journals/ keeps the ones the push checks.
// `--out DIR` writes a diff.py run (receipt.json, checkpoints.jsonl) and divergence.json; the `journals` suite is
// differential, so `diff.py BASE_OUT HEAD_OUT` of two builds' runs is the check, and divergence.json names where
// a build's replay first leaves its recording.
//
// An executable, not a test target (the 2026-10-10 ruling), and not built into the app or run by CI. It reads no
// clock: the same journals on the same host give the same files.
//
//   swift run OracleReplay --out /tmp/o/journals-HEAD --sha HEAD_SHA tests/oracle/corpus/journals
//   python3 -I scripts/cmux-next/oracle/diff.py /tmp/o/journals-BASE /tmp/o/journals-HEAD

import Foundation

/// Loads and replays every journal, one child task each (journals are independent and the VM has hundreds of
/// cores), in input order. The first input that fails, in input order, is the error.
func replayAll(_ inputs: [JournalReader.Input]) async throws(OracleReplayError) -> [ReplayedJournal] {
    let outcomes = await withTaskGroup(of: (Int, Result<ReplayedJournal, OracleReplayError>).self) { group in
        for (index, input) in inputs.enumerated() {
            group.addTask {
                do throws(OracleReplayError) {
                    let journal = try JournalReader().load(input)
                    return (index, .success(ReplayedJournal(journal)))
                } catch {
                    return (index, .failure(error))
                }
            }
        }
        var outcomes = [Result<ReplayedJournal, OracleReplayError>?](repeating: nil, count: inputs.count)
        for await (index, outcome) in group {
            outcomes[index] = outcome
        }
        return outcomes
    }
    var replayed: [ReplayedJournal] = []
    for case let outcome? in outcomes {
        switch outcome {
        case .success(let journal): replayed.append(journal)
        case .failure(let error): throw error
        }
    }
    return replayed
}

func runOracleReplay(_ argv: [String]) async throws(OracleReplayError) -> Int32 {
    let arguments = try ReplayArguments(argv)
    if arguments.help {
        print(ReplayArguments.usage)
        return 0
    }
    let replayed = try await replayAll(JournalReader().inputs(at: arguments.paths))
    let run = ReplayRun(replayed: replayed, runID: arguments.runID ?? arguments.out?.lastPathComponent ?? "oracle-replay",
                        sha: arguments.sha, host: .current())
    if arguments.replayJSON, let only = replayed.first {
        let json = try run.encode(only.result)
        FileHandle.standardOutput.write(json + Data("\n".utf8))
        return only.diverged ? 1 : 0
    }
    if let out = arguments.out { try run.save(in: out) }
    var focus = 0, attach = 0
    for journal in replayed {
        focus += journal.result.focusEvents
        attach += journal.result.attachEvents
        guard let first = journal.first else { continue }
        print("\(journal.journal.caseID): \(journal.result.divergences) divergence(s), first at seq \(first.index) "
            + "\(first.step) \(first.pointer): recorded \(ReplayRun.text(first.a)) replayed \(ReplayRun.text(first.b))")
    }
    let divergent = replayed.filter(\.diverged).count
    print("oracle-replay: \(replayed.count) journal(s), \(focus) focus and \(attach) attach events replayed, "
        + "\(divergent) divergent")
    return divergent == 0 ? 0 : 1
}

do throws(OracleReplayError) {
    let status = try await runOracleReplay(Array(CommandLine.arguments.dropFirst()))
    exit(status)
} catch {
    FileHandle.standardError.write(Data("oracle-replay: \(error)\n".utf8))
    exit(error.exitCode)
}
