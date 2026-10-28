/// Why `oracle-replay` stopped before it could judge every journal. The exit codes are diff.py's:
/// 2 bad input, 4 an output it could not write.
enum OracleReplayError: Error, CustomStringConvertible {
    case usage(String)
    case unreadable(path: String, reason: String)
    case malformed(path: String, line: Int?, reason: String)
    case unwritable(path: String, reason: String)

    var description: String {
        switch self {
        case .usage(let reason): "usage: \(reason)\n\(ReplayArguments.usage)"
        case .unreadable(let path, let reason): "\(path): cannot read: \(reason)"
        case .malformed(let path, let line, let reason): "\(path)\(line.map { ":\($0)" } ?? ""): \(reason)"
        case .unwritable(let path, let reason): "\(path): cannot write: \(reason)"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage, .unreadable, .malformed: 2
        case .unwritable: 4
        }
    }
}
