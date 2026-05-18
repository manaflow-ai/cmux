import Foundation

extension CMUXCLI {
    enum MemorySubcommand: String {
        case snapshot
        case list
        case top
        case trim
    }

    struct MemoryTopCommandOptions {
        let since: TimeInterval
        let jsonOutput: Bool
        let limit: Int
        let sort: MemoryTopSort
    }

    struct MemoryCurrentCommandOptions {
        let workspaceHandle: String?
        let jsonOutput: Bool
        let limit: Int?
    }

    struct MemoryTrimCommandOptions {
        let workspaceHandle: String?
        let agent: String?
        let graceSeconds: TimeInterval
        let dryRun: Bool
        let jsonOutput: Bool
    }

    enum MemoryTopSort: String {
        case peak
        case average

        var payloadValue: String {
            rawValue
        }

        static func parse(_ raw: String?) throws -> MemoryTopSort {
            guard let raw else { return .peak }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "peak", "max", "rss", "peak-rss":
                return .peak
            case "avg", "average", "mean", "avg-rss", "average-rss":
                return .average
            default:
                throw CLIError(message: "--sort must be one of: peak, avg")
            }
        }
    }

    func parseMemorySubcommand(command: String, args: [String]) throws -> (MemorySubcommand, [String]) {
        switch command {
        case "memory-snapshot":
            return (.snapshot, args)
        case "memory-list":
            return (.list, args)
        case "memory-top":
            return (.top, args)
        case "memory-trim":
            return (.trim, args)
        case "memory":
            guard let rawSubcommand = args.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !rawSubcommand.isEmpty else {
                throw CLIError(message: "Usage: cmux memory <snapshot|list|top|trim> [flags]")
            }
            let rest = Array(args.dropFirst())
            switch rawSubcommand {
            case "snapshot", "snap":
                return (.snapshot, rest)
            case "list", "ls":
                return (.list, rest)
            case "top":
                return (.top, rest)
            case "trim":
                return (.trim, rest)
            default:
                throw CLIError(message: "Unknown memory subcommand '\(rawSubcommand)'. Usage: cmux memory <snapshot|list|top|trim> [flags]")
            }
        default:
            throw CLIError(message: "Unknown memory command '\(command)'")
        }
    }

    func parseMemoryCurrentOptions(_ args: [String], commandName: String) throws -> MemoryCurrentCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        let (limitOpt, rem1) = parseOption(rem0, name: "--limit")
        var jsonOutput = false
        var remaining: [String] = []
        for arg in rem1 {
            switch arg {
            case "--json":
                jsonOutput = true
            case "--all":
                continue
            default:
                remaining.append(arg)
            }
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "\(commandName): unknown flag '\(unknown)'. Known flags: --workspace <id|ref|index> --limit <n> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "\(commandName): unexpected argument '\(extra)'")
        }
        let limit = try parsePositiveInt(limitOpt, label: "--limit")
        return MemoryCurrentCommandOptions(
            workspaceHandle: workspaceOpt,
            jsonOutput: jsonOutput,
            limit: limit
        )
    }

    func parseMemoryTopOptions(_ args: [String], jsonOutput globalJSONOutput: Bool) throws -> MemoryTopCommandOptions {
        let (sinceOpt, rem0) = parseOption(args, name: "--since")
        let (limitOpt, rem1) = parseOption(rem0, name: "--limit")
        let (sortOpt, rem2) = parseOption(rem1, name: "--sort")
        var jsonOutput = globalJSONOutput
        var remaining: [String] = []
        for arg in rem2 {
            if arg == "--json" {
                jsonOutput = true
            } else {
                remaining.append(arg)
            }
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "memory top: unknown flag '\(unknown)'. Known flags: --since <duration> --limit <n> --sort <peak|avg> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "memory top: unexpected argument '\(extra)'")
        }
        let since = try parseMemoryDuration(sinceOpt ?? "6h", label: "--since")
        let limit = try parsePositiveInt(limitOpt, label: "--limit") ?? 20
        return MemoryTopCommandOptions(
            since: since,
            jsonOutput: jsonOutput,
            limit: limit,
            sort: try MemoryTopSort.parse(sortOpt)
        )
    }

    func parseMemoryTrimOptions(_ args: [String], jsonOutput globalJSONOutput: Bool) throws -> MemoryTrimCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        let (agentOpt, rem1) = parseOption(rem0, name: "--agent")
        let (graceOpt, rem2) = parseOption(rem1, name: "--grace")
        let (graceSecondsOpt, rem3) = parseOption(rem2, name: "--grace-seconds")
        var dryRun = false
        var jsonOutput = globalJSONOutput
        var remaining: [String] = []
        for arg in rem3 {
            switch arg {
            case "--dry-run":
                dryRun = true
            case "--json":
                jsonOutput = true
            default:
                remaining.append(arg)
            }
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "memory trim: unknown flag '\(unknown)'. Known flags: --workspace <id|ref|index> --agent <name|pid|auto> --grace <duration> --grace-seconds <n> --dry-run --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "memory trim: unexpected argument '\(extra)'")
        }
        let graceSeconds: TimeInterval
        if let graceSecondsOpt {
            graceSeconds = try parseMemoryDuration(graceSecondsOpt, label: "--grace-seconds")
        } else {
            graceSeconds = try parseMemoryDuration(graceOpt ?? "5s", label: "--grace")
        }
        let workspaceHandle = workspaceOpt ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        return MemoryTrimCommandOptions(
            workspaceHandle: workspaceHandle,
            agent: agentOpt,
            graceSeconds: max(0, graceSeconds),
            dryRun: dryRun,
            jsonOutput: jsonOutput
        )
    }

    func parseMemoryDuration(_ raw: String, label: String) throws -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw CLIError(message: "\(label) requires a duration")
        }
        var suffixStart = trimmed.endIndex
        while suffixStart > trimmed.startIndex {
            let previous = trimmed.index(before: suffixStart)
            guard trimmed[previous].isLetter else { break }
            suffixStart = previous
        }
        let numberText = String(trimmed[..<suffixStart])
        let suffix = String(trimmed[suffixStart...])
        guard let value = Double(numberText), value >= 0 else {
            throw CLIError(message: "\(label) must be a non-negative duration like 30s, 15m, 6h, or 1d")
        }
        switch suffix {
        case "", "s", "sec", "secs", "second", "seconds":
            return value
        case "m", "min", "mins", "minute", "minutes":
            return value * 60
        case "h", "hr", "hrs", "hour", "hours":
            return value * 60 * 60
        case "d", "day", "days":
            return value * 60 * 60 * 24
        default:
            throw CLIError(message: "\(label) has unsupported duration unit '\(suffix)'")
        }
    }
}
