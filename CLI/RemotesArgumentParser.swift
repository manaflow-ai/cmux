import Foundation

enum RemotesArgumentError: Error, Equatable {
    case unknownFlag(String)
    case unexpectedArgument(String)
}

/// Pure argument parser for the read/delete remotes verbs.
///
/// The initial behavior mirrors the legacy CLI so regression tests can pin the
/// bug before the production command is switched to this parser.
enum RemotesArgumentParser {
    static func validateList(_ args: [String]) throws {
        _ = args
    }

    static func removeTarget(_ args: [String]) throws -> String? {
        args.first { !$0.hasPrefix("-") }
    }
}
