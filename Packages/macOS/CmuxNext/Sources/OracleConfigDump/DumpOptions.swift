import Foundation

/// Why a dump run stops: bad arguments, an unreadable corpus or a broken envelope.
enum DumpError: Error, CustomStringConvertible {
    case usage(String)
    case unreadable(path: String, reason: String)
    case envelope(file: String, reason: String)

    var description: String {
        switch self {
        case .usage(let message): message
        case .unreadable(let path, let reason): "\(path): \(reason)"
        case .envelope(let file, let reason): "\(file): \(reason)"
        }
    }
}

/// The command line: `--corpus DIR [--out FILE]`.
struct DumpOptions: Sendable {
    let corpus: URL
    let out: URL?

    init(arguments: [String]) throws(DumpError) {
        var corpus: String?
        var out: String?
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            switch argument {
            case "--corpus": corpus = rest.popFirst()
            case "--out": out = rest.popFirst()
            default: throw .usage("unknown argument \(argument)")
            }
        }
        guard let corpus else { throw .usage("usage: OracleConfigDump --corpus DIR [--out FILE]") }
        self.corpus = URL(fileURLWithPath: corpus)
        self.out = out.map { URL(fileURLWithPath: $0) }
    }
}
