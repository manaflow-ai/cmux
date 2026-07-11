import Foundation

struct TranscriptHarvestArguments {
    var claudeRoot: URL
    var codexRoot: URL
    var maxFiles: Int?
    var format: TranscriptHarvestOutputFormat
    var modifiedSince: Date?

    static func parse(_ arguments: [String]) throws -> TranscriptHarvestArguments {
        var parser = TranscriptHarvestArgumentParser(arguments: Array(arguments.dropFirst()))
        return try parser.parse()
    }
}
