import Foundation

/// The command line of `oracle-replay`.
struct ReplayArguments: Sendable {
    static let usage = """
    OracleReplay [--out DIR] [--sha SHA] [--run-id ID] PATH...
    OracleReplay --replay-json JOURNAL
      PATH            a journal (.jsonl, or .json: an entry array, a desync report, a debug.journal reply)
                      or a directory of them (tests/oracle/corpus/journals, a run's journals/)
      --out DIR       write receipt.json and checkpoints.jsonl (diff.py's run format) and divergence.json
      --sha SHA       the commit whose reducers replay (the receipt's sha)
      --run-id ID     the receipt's runId (default: the --out folder's name)
      --replay-json   print the one journal's replay result exactly as debug.replay returns it
    Exit: 0 every replay equals its recording, 1 a divergence, 2 bad input, 4 an output not written.
    """

    var paths: [String] = []
    var out: URL?
    var sha = ""
    var runID: String?
    var replayJSON = false
    var help = false

    init(_ argv: [String]) throws(OracleReplayError) {
        var rest = argv[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--out": out = try URL(fileURLWithPath: Self.value(of: argument, from: &rest), isDirectory: true)
            case "--sha": sha = try Self.value(of: argument, from: &rest)
            case "--run-id": runID = try Self.value(of: argument, from: &rest)
            case "--replay-json": replayJSON = true
            case "-h", "--help": help = true
            default:
                guard !argument.hasPrefix("-") else { throw .usage("unknown option \(argument)") }
                paths.append(argument)
            }
        }
        guard !help else { return }
        guard !paths.isEmpty else { throw .usage("no journal given") }
        if replayJSON, paths.count != 1 || out != nil {
            throw .usage("--replay-json takes exactly one journal and no --out")
        }
    }

    private static func value(of flag: String, from rest: inout ArraySlice<String>) throws(OracleReplayError) -> String {
        guard let value = rest.popFirst(), !value.hasPrefix("--") else { throw .usage("\(flag) needs a value") }
        return value
    }
}
