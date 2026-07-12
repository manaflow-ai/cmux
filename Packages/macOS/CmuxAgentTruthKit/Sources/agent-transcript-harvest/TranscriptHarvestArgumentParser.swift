import Foundation

struct TranscriptHarvestArgumentParser {
    private var arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    mutating func parse() throws -> TranscriptHarvestArguments {
        var claudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
        var codexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        var maxFiles: Int?
        var format = TranscriptHarvestOutputFormat.tsv
        var recentDays: Int?

        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            switch flag {
            case "--claude-root":
                claudeRoot = URL(fileURLWithPath: try value(after: flag), isDirectory: true)
            case "--codex-root":
                codexRoot = URL(fileURLWithPath: try value(after: flag), isDirectory: true)
            case "--max-files":
                maxFiles = try positiveInteger(after: flag)
            case "--format":
                format = try TranscriptHarvestOutputFormat(rawValue: value(after: flag))
                    .orThrow(TranscriptHarvestArgumentError.invalidValue(flag))
            case "--recent-days":
                recentDays = try positiveInteger(after: flag)
            case "--help", "-h":
                throw TranscriptHarvestArgumentError.help
            default:
                throw TranscriptHarvestArgumentError.unknownFlag(flag)
            }
        }

        let modifiedSince = recentDays.map {
            Date().addingTimeInterval(-Double($0) * 24 * 60 * 60)
        }
        return TranscriptHarvestArguments(
            claudeRoot: claudeRoot,
            codexRoot: codexRoot,
            maxFiles: maxFiles,
            format: format,
            modifiedSince: modifiedSince
        )
    }

    private mutating func value(after flag: String) throws -> String {
        guard !arguments.isEmpty else {
            throw TranscriptHarvestArgumentError.missingValue(flag)
        }
        return arguments.removeFirst()
    }

    private mutating func positiveInteger(after flag: String) throws -> Int {
        let rawValue = try value(after: flag)
        guard let value = Int(rawValue), value >= 0 else {
            throw TranscriptHarvestArgumentError.invalidValue(flag)
        }
        return value
    }
}
