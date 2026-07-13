import Foundation

@testable import CmuxAgentChat

struct ArtifactDiscoveryAudit {
    private struct ViolationExample {
        let agent: String
        let transcriptPath: String
        let artifactPath: String
        let channels: String
    }

    private struct TranscriptMeasurement {
        let agent: String
        let transcriptPath: String
        let beforeViolations: Set<String>
        let afterViolations: Set<String>
        let beforeChannels: [String: Set<String>]
        let afterChannels: [String: Set<String>]
        let beforeExtraCount: Int
        let afterExtraCount: Int
        let excludedGalleryPaths: Set<String>
        let nonAbsoluteGalleryPaths: Set<String>
    }

    private let fileManager = FileManager.default
    private let limitPerAgent = 150
    private let detector = TerminalArtifactPathDetector()
    private let codexUserNoisePrefixes = [
        "<user_instructions", "<environment_context", "<permissions",
        "<collaboration_mode", "<turn_aborted", "# AGENTS.md instructions",
    ]
    private let claudeUserNoisePrefixes = [
        "<command-name>", "<local-command", "<system-reminder",
    ]

    func run() {
        let home = fileManager.homeDirectoryForCurrentUser
        let sources = [
            ("claude", newestClaudeTranscripts(root: home.appendingPathComponent(".claude/projects"))),
            ("codex", newestCodexTranscripts(root: home.appendingPathComponent(".codex/sessions"))),
        ]
        var measurements: [TranscriptMeasurement] = []
        for (agent, urls) in sources {
            for url in urls {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let result = parse(lines: lines, agent: agent)
                let cwd = workingDirectory(messages: result.messages, lines: lines)
                let current = snapshot(
                    lines: lines,
                    agent: agent,
                    workingDirectory: cwd,
                    parseResult: result
                )
                let beforeDetected = detectedPaths(
                    lines: lines,
                    agent: agent,
                    workingDirectory: cwd,
                    usesLegacyDetector: true
                )
                let beforeGallery = legacyGalleryPaths(
                    messages: result.messages,
                    workingDirectory: cwd
                )
                let beforeDetectedPaths = Set(beforeDetected.keys)
                measurements.append(
                    TranscriptMeasurement(
                        agent: agent,
                        transcriptPath: url.path,
                        beforeViolations: beforeDetectedPaths.subtracting(beforeGallery),
                        afterViolations: current.violations,
                        beforeChannels: beforeDetected,
                        afterChannels: current.detectedChannelsByPath,
                        beforeExtraCount: beforeGallery.subtracting(beforeDetectedPaths).count,
                        afterExtraCount: current.galleryPaths
                            .subtracting(Set(current.detectedChannelsByPath.keys)).count,
                        excludedGalleryPaths: current.excludedGalleryPaths,
                        nonAbsoluteGalleryPaths: current.nonAbsoluteGalleryPaths
                    )
                )
            }
        }
        printReport(measurements)
    }

    func snapshot(
        lines: [String],
        agent: String,
        workingDirectory: String?,
        parseResult: ChatTranscriptParseResult? = nil
    ) -> ArtifactParityAuditSnapshot {
        // Audit criterion: S ⊇ D − E. TerminalArtifactPathDetector applies E
        // symmetrically to terminal/In-view scanning and gallery free text: bare
        // root or fewer-than-two-component tokens, quote/template/backslash/
        // backtick syntax, and interior parentheses are non-artifacts. The
        // residual E checks below cover URI and pseudo-filesystem namespaces.
        let result = parseResult ?? parse(lines: lines, agent: agent)
        let detected = detectedPaths(
            lines: lines,
            agent: agent,
            workingDirectory: workingDirectory,
            usesLegacyDetector: false
        )
        let artifacts = ChatArtifactIndexedReference.derive(
            from: result.messages,
            supplementalReferences: result.artifactReferences,
            workingDirectory: workingDirectory
        )
        let galleryPaths = Set(artifacts.map(\.path))
        return ArtifactParityAuditSnapshot(
            detectedChannelsByPath: detected,
            galleryPaths: galleryPaths,
            violations: Set(detected.keys).subtracting(galleryPaths),
            excludedGalleryPaths: galleryPaths.filter(Self.isExcludedPath),
            nonAbsoluteGalleryPaths: galleryPaths.filter { !$0.hasPrefix("/") }
        )
    }

    private func parse(lines: [String], agent: String) -> ChatTranscriptParseResult {
        agent == "codex"
            ? CodexTranscriptParser().parse(lines: lines, startingSeq: 0)
            : ClaudeTranscriptParser().parse(lines: lines, startingSeq: 0)
    }

    private func detectedPaths(
        lines: [String],
        agent: String,
        workingDirectory: String?,
        usesLegacyDetector: Bool
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let normalizer = ChatArtifactPathNormalizer(workingDirectory: workingDirectory)
        for line in lines {
            guard let root = TranscriptJSONValue(jsonLine: line) else { continue }
            if agent == "codex" {
                appendCodexTextChannels(
                    root,
                    normalizer: normalizer,
                    usesLegacyDetector: usesLegacyDetector,
                    into: &result
                )
            } else {
                appendClaudeTextChannels(
                    root,
                    normalizer: normalizer,
                    usesLegacyDetector: usesLegacyDetector,
                    into: &result
                )
            }
        }
        return result
    }

    private func appendClaudeTextChannels(
        _ root: TranscriptJSONValue,
        normalizer: ChatArtifactPathNormalizer,
        usesLegacyDetector: Bool,
        into paths: inout [String: Set<String>]
    ) {
        guard let content = root["message"]?["content"] else { return }
        let sidechain = root["isSidechain"]?.bool == true
        switch root["type"]?.string {
        case "user":
            guard root["isMeta"]?.bool != true else { return }
            if let text = content.string, !sidechain {
                appendText(
                    text,
                    channel: "user",
                    normalizer: normalizer,
                    usesLegacyDetector: usesLegacyDetector,
                    noisePrefixes: claudeUserNoisePrefixes,
                    into: &paths
                )
            }
            for block in content.array ?? [] {
                switch block["type"]?.string {
                case "text" where !sidechain:
                    appendText(
                        block["text"]?.string,
                        channel: "user",
                        normalizer: normalizer,
                        usesLegacyDetector: usesLegacyDetector,
                        noisePrefixes: claudeUserNoisePrefixes,
                        into: &paths
                    )
                case "tool_result":
                    appendText(
                        claudeResultText(block["content"]),
                        channel: sidechain ? "sidechain-output" : "output",
                        normalizer: normalizer,
                        usesLegacyDetector: usesLegacyDetector,
                        into: &paths
                    )
                default:
                    continue
                }
            }
        case "assistant":
            for block in content.array ?? [] {
                switch block["type"]?.string {
                case "text" where !sidechain:
                    appendText(
                        block["text"]?.string,
                        channel: "prose",
                        normalizer: normalizer,
                        usesLegacyDetector: usesLegacyDetector,
                        into: &paths
                    )
                case "thinking" where !sidechain:
                    appendText(
                        block["thinking"]?.string,
                        channel: "thought",
                        normalizer: normalizer,
                        usesLegacyDetector: usesLegacyDetector,
                        into: &paths
                    )
                case "tool_use":
                    guard block["name"]?.string == "Bash" else { continue }
                    appendText(
                        block["input"]?["command"]?.string,
                        channel: sidechain ? "sidechain-command" : "command",
                        normalizer: normalizer,
                        usesLegacyDetector: usesLegacyDetector,
                        into: &paths
                    )
                default:
                    continue
                }
            }
        default:
            return
        }
    }

    private func appendCodexTextChannels(
        _ root: TranscriptJSONValue,
        normalizer: ChatArtifactPathNormalizer,
        usesLegacyDetector: Bool,
        into paths: inout [String: Set<String>]
    ) {
        let payload = root["payload"]
        switch root["type"]?.string {
        case "response_item":
            switch payload?["type"]?.string {
            case "message":
                let role = payload?["role"]?.string
                let channel = role == "user" ? "user" : "prose"
                guard role == "user" || role == "assistant" else { return }
                for block in payload?["content"]?.array ?? [] {
                    appendText(
                        block["text"]?.string,
                        channel: channel,
                        normalizer: normalizer,
                        usesLegacyDetector: usesLegacyDetector,
                        noisePrefixes: role == "user" ? codexUserNoisePrefixes : [],
                        into: &paths
                    )
                }
            case "reasoning":
                for summary in payload?["summary"]?.array ?? [] {
                    appendText(
                        summary["text"]?.string,
                        channel: "thought",
                        normalizer: normalizer,
                        usesLegacyDetector: usesLegacyDetector,
                        into: &paths
                    )
                }
            case "function_call":
                guard let name = payload?["name"]?.string,
                      Self.isCodexShellTool(name) else { return }
                let arguments = payload?["arguments"]?.string
                    .flatMap { TranscriptJSONValue(jsonLine: $0) }
                appendText(
                    codexShellCommand(arguments: arguments, payload: payload),
                    channel: "command",
                    normalizer: normalizer,
                    usesLegacyDetector: usesLegacyDetector,
                    into: &paths
                )
            case "function_call_output", "custom_tool_call_output":
                appendText(
                    codexOutputText(payload?["output"]),
                    channel: "output",
                    normalizer: normalizer,
                    usesLegacyDetector: usesLegacyDetector,
                    into: &paths
                )
            default:
                return
            }
        case "event_msg":
            switch payload?["type"]?.string {
            case "agent_message":
                appendText(
                    payload?["message"]?.string,
                    channel: "prose",
                    normalizer: normalizer,
                    usesLegacyDetector: usesLegacyDetector,
                    into: &paths
                )
            case "exec_command_begin":
                appendEventFields(
                    payload,
                    keys: ["command", "cmd"],
                    channel: "command",
                    normalizer: normalizer,
                    usesLegacyDetector: usesLegacyDetector,
                    into: &paths
                )
            case "exec_command_end", "exec_command_output_delta", "patch_apply_end":
                appendEventFields(
                    payload,
                    keys: ["output", "stdout", "stderr", "aggregated_output", "formatted_output", "delta"],
                    channel: "output",
                    normalizer: normalizer,
                    usesLegacyDetector: usesLegacyDetector,
                    into: &paths
                )
            default:
                return
            }
        default:
            return
        }
    }

    private func appendEventFields(
        _ payload: TranscriptJSONValue?,
        keys: [String],
        channel: String,
        normalizer: ChatArtifactPathNormalizer,
        usesLegacyDetector: Bool,
        into paths: inout [String: Set<String>]
    ) {
        for key in keys {
            appendText(
                codexOutputText(payload?[key]),
                channel: channel,
                normalizer: normalizer,
                usesLegacyDetector: usesLegacyDetector,
                into: &paths
            )
        }
    }

    private func appendText(
        _ text: String?,
        channel: String,
        normalizer: ChatArtifactPathNormalizer,
        usesLegacyDetector: Bool,
        noisePrefixes: [String] = [],
        into paths: inout [String: Set<String>]
    ) {
        guard let text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !noisePrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return }
        let candidates = usesLegacyDetector ? legacyPaths(in: text) : detector.paths(in: text)
        for candidate in candidates {
            guard ChatArtifactPathNormalizer.isAbsoluteFreeTextCandidate(candidate),
                  let path = normalizer.freeTextPath(candidate) else { continue }
            paths[path, default: []].insert(channel)
        }
    }

    private func legacyPaths(in text: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in text.split(whereSeparator: \.isWhitespace) {
            var candidate = String(raw)
            let leading = CharacterSet(charactersIn: "\"'`([{<")
            let trailing = CharacterSet(charactersIn: "\"'`)]}>,;:!?")
            candidate = candidate.trimmingCharacters(in: leading)
            while let scalar = candidate.unicodeScalars.last,
                  trailing.contains(scalar) || (scalar.value == 46 && !candidate.hasSuffix("..")) {
                candidate.removeLast()
            }
            if candidate.hasPrefix("file://"),
               let url = URL(string: candidate), url.isFileURL {
                candidate = url.path
            }
            guard !candidate.isEmpty,
                  !candidate.hasPrefix("http://"),
                  !candidate.hasPrefix("https://"),
                  (candidate.hasPrefix("/") || candidate.hasPrefix("./")
                    || candidate.hasPrefix("../")
                    || (candidate.contains("/") && !candidate.contains("://"))),
                  seen.insert(candidate).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    private func claudeResultText(_ content: TranscriptJSONValue?) -> String? {
        if let text = content?.string { return text }
        let texts = (content?.array ?? []).compactMap { block -> String? in
            guard block["type"]?.string == "text" else { return nil }
            return block["text"]?.string
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private func codexOutputText(_ value: TranscriptJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            if let nested = TranscriptJSONValue(jsonLine: text),
               let inner = codexOutputText(nested["output"]) {
                return inner
            }
            return text
        case .array(let blocks):
            let texts = blocks.compactMap { block -> String? in
                block.string ?? block["text"]?.string
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        case .object:
            return codexOutputText(value["output"])
                ?? codexOutputText(value["content"])
                ?? value["text"]?.string
        case .number, .bool, .null:
            return nil
        }
    }

    private func codexShellCommand(
        arguments: TranscriptJSONValue?,
        payload: TranscriptJSONValue?
    ) -> String? {
        if let cmd = arguments?["cmd"]?.string { return cmd }
        if let command = arguments?["command"]?.string { return command }
        let parts = arguments?["command"]?.array ?? payload?["action"]?["command"]?.array
        let strings = parts?.compactMap(\.string) ?? []
        guard !strings.isEmpty else { return nil }
        if strings.count >= 3,
           let binary = strings[0].split(separator: "/").last,
           ["bash", "sh", "zsh"].contains(String(binary)),
           strings[1] == "-lc" || strings[1] == "-c" {
            return strings[2...].joined(separator: " ")
        }
        return strings.joined(separator: " ")
    }

    private func legacyGalleryPaths(
        messages: [ChatMessage],
        workingDirectory: String?
    ) -> Set<String> {
        let normalizer = ChatArtifactPathNormalizer(workingDirectory: workingDirectory)
        var paths: Set<String> = []
        for message in messages {
            let rawPaths: [String]
            switch message.kind {
            case .fileEdit(let edit):
                rawPaths = [edit.filePath]
            case .attachment(let attachment):
                rawPaths = attachment.hostPath.map { [$0] } ?? []
            case .toolUse(let toolUse):
                rawPaths = toolUse.referencedPaths ?? []
            default:
                rawPaths = []
            }
            for rawPath in rawPaths {
                if let path = normalizer.structuredPath(rawPath), path.hasPrefix("/") {
                    paths.insert(path)
                }
            }
        }
        return paths
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

    private func printReport(_ measurements: [TranscriptMeasurement]) {
        for agent in ["claude", "codex"] {
            let subset = measurements.filter { $0.agent == agent }
            printAggregate(label: agent, measurements: subset)
        }
        printAggregate(label: "total", measurements: measurements)
        printExamples(phase: "before", measurements: measurements, usesAfter: false)
        printExamples(phase: "after", measurements: measurements, usesAfter: true)
        let beforeExtras = measurements.map(\.beforeExtraCount)
        let afterExtras = measurements.map(\.afterExtraCount)
        let growth = zip(beforeExtras, afterExtras).map { before, after in
            Double(after + 1) / Double(before + 1)
        }
        print(
            "ARTIFACT_PARITY_GROWTH "
                + "before_extra_median=\(percentile(beforeExtras, percentile: 0.50)) "
                + "before_extra_p95=\(percentile(beforeExtras, percentile: 0.95)) "
                + "after_extra_median=\(percentile(afterExtras, percentile: 0.50)) "
                + "after_extra_p95=\(percentile(afterExtras, percentile: 0.95)) "
                + "factor_median=\(String(format: "%.3f", percentile(growth, percentile: 0.50))) "
                + "factor_p95=\(String(format: "%.3f", percentile(growth, percentile: 0.95)))"
        )
    }

    private func printAggregate(label: String, measurements: [TranscriptMeasurement]) {
        let beforeTranscripts = measurements.filter { !$0.beforeViolations.isEmpty }.count
        let afterTranscripts = measurements.filter { !$0.afterViolations.isEmpty }.count
        let beforePairs = measurements.reduce(0) { $0 + $1.beforeViolations.count }
        let afterPairs = measurements.reduce(0) { $0 + $1.afterViolations.count }
        let excluded = measurements.reduce(0) { $0 + $1.excludedGalleryPaths.count }
        let nonAbsolute = measurements.reduce(0) { $0 + $1.nonAbsoluteGalleryPaths.count }
        print(
            "ARTIFACT_PARITY_AGGREGATE agent=\(label) transcripts=\(measurements.count) "
                + "before_violation_transcripts=\(beforeTranscripts) before_pairs=\(beforePairs) "
                + "after_violation_transcripts=\(afterTranscripts) after_pairs=\(afterPairs) "
                + "excluded_gallery=\(excluded) non_absolute_gallery=\(nonAbsolute)"
        )
    }

    private func printExamples(
        phase: String,
        measurements: [TranscriptMeasurement],
        usesAfter: Bool
    ) {
        var examples: [ViolationExample] = []
        for measurement in measurements {
            let violations = usesAfter ? measurement.afterViolations : measurement.beforeViolations
            let channels = usesAfter ? measurement.afterChannels : measurement.beforeChannels
            for path in violations {
                examples.append(
                    ViolationExample(
                        agent: measurement.agent,
                        transcriptPath: measurement.transcriptPath,
                        artifactPath: path,
                        channels: (channels[path] ?? []).sorted().joined(separator: ",")
                    )
                )
            }
        }
        examples.sort {
            ($0.agent, $0.transcriptPath, $0.artifactPath)
                < ($1.agent, $1.transcriptPath, $1.artifactPath)
        }
        for (index, example) in examples.prefix(10).enumerated() {
            print(
                "ARTIFACT_PARITY_EXAMPLE phase=\(phase) rank=\(index + 1) "
                    + "agent=\(example.agent) channel=\(example.channels) "
                    + "path=\(example.artifactPath) transcript=\(example.transcriptPath)"
            )
        }
    }

    private func percentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
        return sorted[index]
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
        return sorted[index]
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
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            return left > right
        }.prefix(limitPerAgent).map { $0 }
    }

    private static func isCodexShellTool(_ name: String) -> Bool {
        ["shell", "exec_command", "local_shell_call", "container.exec"].contains(name)
    }

    private static func isExcludedPath(_ path: String) -> Bool {
        !path.hasPrefix("/")
            || path.contains("://")
            || ["/dev", "/proc", "/sys"].contains { prefix in
                path == prefix || path.hasPrefix(prefix + "/")
            }
    }
}
