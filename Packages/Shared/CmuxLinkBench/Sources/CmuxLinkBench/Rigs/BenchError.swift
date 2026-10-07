/// Why a benchmark step could not run.
enum BenchError: Error, CustomStringConvertible {
    case setup(String)
    case timeout(String)
    case unexpected(String)

    var description: String {
        switch self {
        case let .setup(message): "setup: \(message)"
        case let .timeout(message): "timeout: \(message)"
        case let .unexpected(message): "unexpected: \(message)"
        }
    }
}
