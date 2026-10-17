import Foundation

enum RemotesArgumentError: Error, Equatable {
    case unknownFlag(String)
    case unexpectedArgument(String)
    case missingOptionValue(String)
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
        var positionals: [String] = []
        var afterTerminator = false
        for argument in args {
            if !afterTerminator, argument == "--json" {
                continue
            }
            if !afterTerminator, argument == "--" {
                afterTerminator = true
                continue
            }
            if !afterTerminator, argument.hasPrefix("-") {
                throw RemotesArgumentError.unknownFlag(argument)
            }
            positionals.append(argument)
        }
        if positionals.count > expectedCount,
           let extra = positionals.dropFirst(expectedCount).first {
            throw RemotesArgumentError.unexpectedArgument(extra)
        }
        return positionals
    }
}
