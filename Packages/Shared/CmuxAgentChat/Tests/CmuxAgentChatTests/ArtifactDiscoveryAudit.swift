import Foundation
@testable import CmuxAgentChat

struct ArtifactDiscoveryAudit {
    private let fileManager = FileManager.default
    private let limitPerAgent = 150
    private let pathKeys: Set<String> = ["file_path", "notebook_path", "path"]
    private let commandKeys: Set<String> = ["cmd", "command", "args"]

    func run() {
        let home = fileManager.homeDirectoryForCurrentUser
        let claude = newestClaudeTranscripts(root: home.appendingPathComponent(".claude/projects"))
        let codex = newestCodexTranscripts(root: home.appendingPathComponent(".codex/sessions"))
        var categoryCounts: [String: Int] = [:]
        var categoryExamples: [String: String] = [:]
        var transcriptCount = 0
        var suspiciousCount = 0

        for (agent, urls) in [("claude", claude), ("codex", codex)] {
            for url in urls {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let messages: [ChatMessage]
                if agent == "codex" {
                    messages = CodexTranscriptParser().parse(lines: lines, startingSeq: 0).messages
                } else {
                    messages = ClaudeTranscriptParser().parse(lines: lines, startingSeq: 0).messages
                }
                let cwd = workingDirectory(messages: messages, lines: lines)
                let artifacts = ChatArtifactIndexedReference.derive(
                    from: messages,
                    workingDirectory: cwd
                )
                let raw = rawMetrics(lines: lines, agent: agent)
                let parsedToolUses = messages.compactMap { message -> ChatToolUse? in
                    guard case .toolUse(let toolUse) = message.kind else { return nil }
                    return toolUse
                }
                let referencedPathCount = parsedToolUses.reduce(0) { partial, toolUse in
                    partial + (toolUse.referencedPaths?.count ?? 0)
                }
                let createdCount = artifacts.filter { $0.provenance == .created }.count
                let attachedCount = artifacts.filter { $0.provenance == .attached }.count
                let unresolvedRelativeCount = artifacts.filter { !$0.path.hasPrefix("/") }.count
                var categories: [String] = []
                if raw.writeEditCount > 0 && createdCount == 0 {
                    categories.append("edit-tools-without-created-items")
                }
                if raw.pathLikeToolUseCount > 5 && referencedPathCount == 0 {
                    categories.append("path-like-inputs-without-referenced-paths")
                }
                if raw.relativePathCount > 0 {
                    categories.append("relative-file-path-values")
                }
                if unresolvedRelativeCount > 0 {
                    categories.append(cwd == nil ? "relative-paths-missing-session-cwd" : "relative-paths-not-resolved-at-index")
                }
                if raw.hasTmpAliasMixture {
                    categories.append("tmp-private-tmp-mixtures")
                }
                if !raw.skippedPathToolNames.isEmpty {
                    categories.append("unknown-tools-with-path-like-inputs")
                }
                if raw.applyPatchCount > 0 && createdCount == 0 {
                    categories.append("apply-patch-without-created-items")
                }
                if raw.shellHeredocWriteCount > 0 {
                    categories.append("shell-heredoc-writes-not-derived")
                }
                if raw.shellRedirectionWriteCount > 0 {
                    categories.append("shell-redirection-writes-not-derived")
                }
                let suspicious = !categories.isEmpty
                transcriptCount += 1
                if suspicious { suspiciousCount += 1 }
                for category in Set(categories) {
                    categoryCounts[category, default: 0] += 1
                    categoryExamples[category] = categoryExamples[category] ?? url.path
                }
                let skipped = raw.skippedPathToolNames.sorted().joined(separator: ",")
                print(
                    "ARTIFACT_AUDIT \(suspicious ? "SUSPICIOUS" : "OK") path=\(url.path) "
                    + "messages=\(messages.count) tool_use=\(raw.toolUseCount) "
                    + "path_like_inputs=\(raw.pathLikeToolUseCount) referenced_paths=\(referencedPathCount) "
                    + "write_edit=\(raw.writeEditCount) created=\(createdCount) "
                    + "attachment_tokens=\(raw.attachmentTokenCount) attached=\(attachedCount) "
                    + "relative_file_path=\(raw.relativePathCount) unresolved_relative=\(unresolvedRelativeCount) "
                    + "tmp_alias_mixture=\(raw.hasTmpAliasMixture ? 1 : 0) "
                    + "skipped_tools=\(skipped.isEmpty ? "none" : skipped)"
                )
            }
        }

        print("ARTIFACT_AUDIT_AGGREGATE transcripts=\(transcriptCount) suspicious=\(suspiciousCount)")
        let topCategories = categoryCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.prefix(5)
        for (index, entry) in topCategories.enumerated() {
            let category = entry.key
            print(
                "ARTIFACT_AUDIT_GAP rank=\(index + 1) category=\(category) "
                + "count=\(entry.value) example=\(categoryExamples[category] ?? "none")"
            )
        }
    }

    private func newestClaudeTranscripts(root: URL) -> [URL] {
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let files = projectDirectories.flatMap { directory -> [URL] in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else { return [] }
            return children.filter { $0.pathExtension == "jsonl" }
        }
        return newest(files)
    }

    private func newestCodexTranscripts(root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where
            url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            files.append(url)
        }
        return newest(files)
    }

    private func newest(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            return left > right
        }.prefix(limitPerAgent).map { $0 }
    }

    private func workingDirectory(messages: [ChatMessage], lines: [String]) -> String? {
        for message in messages {
            guard case .status(let status) = message.kind,
                  status.event == .sessionStarted,
                  let detail = status.detail,
                  detail.hasPrefix("/") else { continue }
            return detail
        }
        for line in lines {
            guard let root = TranscriptJSONValue(jsonLine: line),
                  let cwd = root["cwd"]?.string ?? root["payload"]?["cwd"]?.string,
                  cwd.hasPrefix("/") else { continue }
            return cwd
        }
        return nil
    }

    private func rawMetrics(
        lines: [String],
        agent: String
    ) -> (
        toolUseCount: Int,
        pathLikeToolUseCount: Int,
        writeEditCount: Int,
        relativePathCount: Int,
        attachmentTokenCount: Int,
        applyPatchCount: Int,
        shellHeredocWriteCount: Int,
        shellRedirectionWriteCount: Int,
        hasTmpAliasMixture: Bool,
        skippedPathToolNames: Set<String>
    ) {
        var toolUseCount = 0
        var pathLikeToolUseCount = 0
        var writeEditCount = 0
        var relativePathCount = 0
        var attachmentTokenCount = 0
        var applyPatchCount = 0
        var shellHeredocWriteCount = 0
        var shellRedirectionWriteCount = 0
        var hasTmp = false
        var hasPrivateTmp = false
        var skippedPathToolNames: Set<String> = []

        for line in lines {
            attachmentTokenCount += line.components(separatedBy: "<cmux-attachment").count - 1
            guard let root = TranscriptJSONValue(jsonLine: line) else { continue }
            let tools = agent == "claude" ? claudeTools(root: root) : codexTools(root: root)
            for tool in tools {
                toolUseCount += 1
                let keyedPaths = pathValues(in: tool.input, key: nil)
                let broadPathValues = potentialPathValues(in: tool.input, key: nil)
                var commandStrings = strings(in: tool.input, matchingKeys: commandKeys, key: nil)
                if Self.isShellTool(tool.name), let directInput = tool.input?.string {
                    commandStrings.append(directInput)
                }
                let commandAbsolutePathCount = commandStrings.reduce(0) { $0 + absolutePathCount(in: $1) }
                let patchPaths = Self.isApplyPatchTool(tool.name)
                    ? patchedPaths(in: tool.input?.string ?? "")
                    : []
                if !broadPathValues.isEmpty || commandAbsolutePathCount > 0 || !patchPaths.isEmpty {
                    pathLikeToolUseCount += 1
                    if broadPathValues.count > keyedPaths.count {
                        skippedPathToolNames.insert(tool.name)
                    }
                }
                relativePathCount += keyedPaths.filter { !$0.hasPrefix("/") && !$0.isEmpty }.count
                if ["Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch"].contains(tool.name) {
                    writeEditCount += 1
                }
                if Self.isApplyPatchTool(tool.name) {
                    applyPatchCount += 1
                }
                for value in broadPathValues + commandStrings + patchPaths {
                    hasTmp = hasTmp || value.contains("/tmp/")
                    hasPrivateTmp = hasPrivateTmp || value.contains("/private/tmp/")
                }
                for command in commandStrings {
                    if command.contains("<<") && command.contains(">") {
                        shellHeredocWriteCount += 1
                    } else if command.range(of: #"(^|[[:space:]])[12]?>[>]?[[:space:]]*[^&]"#, options: .regularExpression) != nil {
                        shellRedirectionWriteCount += 1
                    }
                }
            }
        }
        return (
            toolUseCount, pathLikeToolUseCount, writeEditCount, relativePathCount,
            attachmentTokenCount, applyPatchCount, shellHeredocWriteCount,
            shellRedirectionWriteCount, hasTmp && hasPrivateTmp, skippedPathToolNames
        )
    }

    private func claudeTools(root: TranscriptJSONValue) -> [(name: String, input: TranscriptJSONValue?)] {
        guard root["type"]?.string == "assistant" else { return [] }
        return (root["message"]?["content"]?.array ?? []).compactMap { block in
            guard block["type"]?.string == "tool_use", let name = block["name"]?.string else { return nil }
            return (name, block["input"])
        }
    }

    private func codexTools(root: TranscriptJSONValue) -> [(name: String, input: TranscriptJSONValue?)] {
        guard root["type"]?.string == "response_item",
              let payload = root["payload"],
              let type = payload["type"]?.string,
              type == "function_call" || type == "custom_tool_call",
              let name = payload["name"]?.string else { return [] }
        if type == "function_call", let arguments = payload["arguments"]?.string {
            return [(name, TranscriptJSONValue(jsonLine: arguments))]
        }
        return [(name, payload["input"])]
    }

    private func pathValues(in value: TranscriptJSONValue?, key: String?) -> [String] {
        guard let value else { return [] }
        if let key, pathKeys.contains(key) {
            return allStrings(in: value)
        }
        switch value {
        case .object(let object):
            return object.flatMap { pathValues(in: $0.value, key: $0.key) }
        case .array(let array):
            return array.flatMap { pathValues(in: $0, key: nil) }
        case .string, .number, .bool, .null:
            return []
        }
    }

    private func potentialPathValues(in value: TranscriptJSONValue?, key: String?) -> [String] {
        guard let value else { return [] }
        if let key, Self.isPotentialPathKey(key) {
            return allStrings(in: value)
        }
        switch value {
        case .object(let object):
            return object.flatMap { potentialPathValues(in: $0.value, key: $0.key) }
        case .array(let array):
            return array.flatMap { potentialPathValues(in: $0, key: nil) }
        case .string, .number, .bool, .null:
            return []
        }
    }

    private func strings(
        in value: TranscriptJSONValue?,
        matchingKeys keys: Set<String>,
        key: String?
    ) -> [String] {
        guard let value else { return [] }
        if let key, keys.contains(key) {
            return allStrings(in: value)
        }
        switch value {
        case .object(let object):
            return object.flatMap { strings(in: $0.value, matchingKeys: keys, key: $0.key) }
        case .array(let array):
            return array.flatMap { strings(in: $0, matchingKeys: keys, key: nil) }
        case .string, .number, .bool, .null:
            return []
        }
    }

    private func allStrings(in value: TranscriptJSONValue) -> [String] {
        switch value {
        case .string(let string): return [string.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .array(let array): return array.flatMap(allStrings(in:))
        case .object(let object): return object.values.flatMap(allStrings(in:))
        case .number, .bool, .null: return []
        }
    }

    private func absolutePathCount(in string: String) -> Int {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])/(?:[^\s'\";|<>]+)"#)
        return regex?.numberOfMatches(in: string, range: range) ?? 0
    }

    private func patchedPaths(in patch: String) -> [String] {
        patch.matches(of: /\*\*\* (?:Update|Add|Delete) File: ([^\r\n]+)/).map {
            String($0.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func isApplyPatchTool(_ name: String) -> Bool {
        let normalized = name.split(separator: ".").last.map(String.init) ?? name
        return normalized.lowercased() == "apply_patch"
    }

    private static func isShellTool(_ name: String) -> Bool {
        let normalized = name.split(separator: ".").last.map(String.init) ?? name
        return ["Bash", "exec", "exec_command", "local_shell_call", "shell"].contains(normalized)
    }

    private static func isPotentialPathKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.contains("path")
            || ["file", "files", "filename", "notebook", "target_file"].contains(normalized)
    }
}
