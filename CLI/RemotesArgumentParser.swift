import Foundation

enum RemotesArgumentError: Error, Equatable {
    case unknownFlag(String)
    case unexpectedArgument(String)
}

/// Pure argument parser for the read/delete remotes verbs.
enum RemotesArgumentParser {
    static func validateList(_ args: [String]) throws {
        _ = try validatedPositionals(args, expectedCount: 0)
    }

    static func removeTarget(_ args: [String]) throws -> String? {
        try validatedPositionals(args, expectedCount: 1).first
    }

    private static func validatedPositionals(
        _ args: [String],
        expectedCount: Int
    ) throws -> [String] {
        let remaining = args.filter { $0 != "--json" }
        if let unknown = remaining.first(where: { $0.hasPrefix("-") }) {
            throw RemotesArgumentError.unknownFlag(unknown)
        }
        if remaining.count > expectedCount,
           let extra = remaining.dropFirst(expectedCount).first {
            throw RemotesArgumentError.unexpectedArgument(extra)
        }
        return remaining
    }
}
