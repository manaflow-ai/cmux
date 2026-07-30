public import Foundation

/// Pure parsers for provider command and configuration output.
public struct MobileTaskModelParser: Sendable {
    /// Creates a model parser.
    public init() {}

    /// Parses nonblank OpenCode output lines as model identifiers.
    ///
    /// Duplicate identifiers are removed while preserving first-seen order.
    ///
    /// - Parameter output: Standard output from `opencode models`.
    /// - Returns: Unique, nonblank model identifiers in output order.
    public func openCodeModelIDs(from output: String) -> [String] {
        uniqueNonemptyStrings(
            output.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    /// Parses a top-level quoted `model = "..."` assignment from Codex TOML.
    ///
    /// - Parameter data: UTF-8 contents of `~/.codex/config.toml`.
    /// - Returns: The configured nonblank model identifier, if present.
    public func codexConfiguredModel(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // A TOML table header changes the scope for every following key.
            // The configured default we want is only valid before that point.
            if trimmed.hasPrefix("[") {
                return nil
            }
            guard !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model"
            else {
                continue
            }
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.first == "\"",
                  let closingQuote = value.dropFirst().firstIndex(of: "\"")
            else {
                return nil
            }
            let model = value[value.index(after: value.startIndex)..<closingQuote]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? nil : model
        }
        return nil
    }

    /// Parses the top-level `model` string from Claude settings JSON.
    ///
    /// - Parameter data: Contents of `~/.claude/settings.json`.
    /// - Returns: The configured nonblank model identifier, if present.
    public func claudeConfiguredModel(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rawModel = object["model"] as? String else {
            return nil
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    private func uniqueNonemptyStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
