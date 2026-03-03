import Foundation

/// Parses Claude Code JSONL session logs to aggregate token usage and estimate costs.
/// Used by SchedulerPage to display per-task and total cost tracking.
enum ClaudeTokenTracker {

    struct TokenUsage: Equatable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheCreationTokens: Int = 0
        var cacheReadTokens: Int = 0

        var totalTokens: Int {
            inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        }

        /// Rough cost estimate in USD based on Claude Opus pricing.
        /// Input: $15/MTok, Output: $75/MTok, Cache write: $18.75/MTok, Cache read: $1.50/MTok
        var estimatedCostUSD: Double {
            let input = Double(inputTokens) / 1_000_000.0 * 15.0
            let output = Double(outputTokens) / 1_000_000.0 * 75.0
            let cacheWrite = Double(cacheCreationTokens) / 1_000_000.0 * 18.75
            let cacheRead = Double(cacheReadTokens) / 1_000_000.0 * 1.50
            return input + output + cacheWrite + cacheRead
        }

        mutating func add(_ other: TokenUsage) {
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            cacheCreationTokens += other.cacheCreationTokens
            cacheReadTokens += other.cacheReadTokens
        }
    }

    /// Aggregate token usage across all Claude Code sessions in the projects directory.
    static func aggregateUsage(projectsDirectory: URL? = nil) -> TokenUsage {
        let dir = projectsDirectory ?? defaultProjectsDirectory()
        guard let dir else { return TokenUsage() }

        var total = TokenUsage()

        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return total }

        for subdir in subdirs where subdir.hasDirectoryPath {
            let jsonlFiles = (try? FileManager.default.contentsOfDirectory(
                at: subdir, includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "jsonl" } ?? []

            for file in jsonlFiles {
                total.add(parseJSONL(at: file))
            }
        }

        // Also check for JSONL files directly in the projects dir (flat layout)
        let topLevelJSONL = subdirs.filter { $0.pathExtension == "jsonl" }
        for file in topLevelJSONL {
            total.add(parseJSONL(at: file))
        }

        return total
    }

    /// Parse a single JSONL file and extract token usage from assistant messages.
    static func parseJSONL(at url: URL) -> TokenUsage {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return TokenUsage()
        }

        var usage = TokenUsage()
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usageDict = message["usage"] as? [String: Any] else { continue }

            if let input = usageDict["input_tokens"] as? Int {
                usage.inputTokens += input
            }
            if let output = usageDict["output_tokens"] as? Int {
                usage.outputTokens += output
            }
            if let cacheCreation = usageDict["cache_creation_input_tokens"] as? Int {
                usage.cacheCreationTokens += cacheCreation
            }
            if let cacheRead = usageDict["cache_read_input_tokens"] as? Int {
                usage.cacheReadTokens += cacheRead
            }
        }

        return usage
    }

    /// Format a cost in USD for display.
    static func formatCost(_ usd: Double) -> String {
        if usd < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", usd)
    }

    /// Format a token count for display (e.g. "1.2M", "45K", "123").
    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    // MARK: - Private

    private static func defaultProjectsDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude/projects", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return dir
    }
}
