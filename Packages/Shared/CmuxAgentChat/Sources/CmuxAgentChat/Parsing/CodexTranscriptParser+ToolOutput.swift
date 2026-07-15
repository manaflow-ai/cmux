import Foundation

extension CodexTranscriptParser {
    /// Extracts the human-meaningful command line from a shell-style call.
    ///
    /// Handles `{"cmd": "..."}` (current `exec_command`), `{"command":
    /// "..."}`, and `{"command": ["bash", "-lc", "actual"]}` (older
    /// `shell`), plus the `local_shell_call` `action.command` array.
    func shellCommand(
        arguments: TranscriptJSONValue?,
        payload: TranscriptJSONValue
    ) -> String? {
        if let cmd = arguments?["cmd"]?.string { return cmd }
        if let cmd = arguments?["command"]?.string { return cmd }
        let parts = arguments?["command"]?.array ?? payload["action"]?["command"]?.array
        guard let parts else { return nil }
        let strings = parts.compactMap(\.string)
        guard !strings.isEmpty else { return nil }
        if strings.count >= 3,
            let binary = strings[0].split(separator: "/").last,
            Self.shellWrapperBinaries.contains(String(binary)),
            strings[1] == "-lc" || strings[1] == "-c" {
            return strings[2...].joined(separator: " ")
        }
        return strings.joined(separator: " ")
    }

    func patchedFiles(in patch: String) -> [String] {
        let paths = patch.matches(of: /\*\*\* (?:Update|Add|Delete) File: ([^\r\n]+)/).map {
            String($0.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return deduplicatedPaths(paths)
    }

    func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func isApplyPatchTool(_ name: String) -> Bool {
        let normalized = name.split(separator: ".").last.map(String.init) ?? name
        return normalized.lowercased() == "apply_patch"
    }

    func blockID(lineID: String, emitted: Int) -> String {
        emitted == 0 ? lineID : "\(lineID)#\(emitted)"
    }

    // MARK: - Tool outputs

    func resolveOutput(
        _ payload: TranscriptJSONValue,
        seq: Int,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let callID = payload["call_id"]?.string else { return }
        let completion = completion(from: payload["output"])
        if let output = completion.output {
            assembler.appendArtifactReferences(paths: artifactText.paths(in: output), seq: seq)
        }
        assembler.resolve(key: callID, completion: completion)
    }

    /// Builds a completion from an output payload, which is a plain string,
    /// a JSON-encoded `{"output": ..., "metadata": {"exit_code": ...}}`
    /// string, or that object inline; exit code and wall time also appear
    /// as text headers (`Process exited with code N`, `Exit code: N`,
    /// `Wall time: S seconds`).
    private func completion(from value: TranscriptJSONValue?) -> TranscriptToolCompletion {
        var text = outputText(from: value)
        var exitCode = value?["metadata"]?["exit_code"]?.int
        var duration = value?["metadata"]?["duration_seconds"]?.double
        if let raw = text,
            let nested = TranscriptJSONValue(jsonLine: raw),
            let inner = outputText(from: nested["output"]) {
            text = inner
            exitCode = nested["metadata"]?["exit_code"]?.int ?? exitCode
            duration = nested["metadata"]?["duration_seconds"]?.double ?? duration
        }
        if exitCode == nil, let text {
            let head = text.prefix(400)
            if let match = head.firstMatch(
                of: /(?:Process exited with code|Exit code:?|exited with code) (-?\d+)/
            ) {
                exitCode = Int(match.1)
            }
        }
        if duration == nil, let text,
            let match = text.prefix(400).firstMatch(of: /Wall time: ([0-9.]+) seconds/) {
            duration = Double(match.1)
        }
        return TranscriptToolCompletion(
            output: text,
            isError: (exitCode ?? 0) != 0,
            exitCode: exitCode,
            durationSeconds: duration
        )
    }

    /// Extracts renderable output from strings, inline/nested output objects,
    /// and text-block arrays used by newer custom tool call records.
    private func outputText(from value: TranscriptJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            return text
        case .array(let blocks):
            let texts = blocks.compactMap { block -> String? in
                guard let text = block["text"]?.string else { return nil }
                return text
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        case .object:
            return outputText(from: value["output"])
                ?? outputText(from: value["content"])
                ?? value["text"]?.string
        case .number, .bool, .null:
            return nil
        }
    }

    /// Scans command/output fields emitted only through Codex event messages.
    func appendEventTextArtifacts(
        _ payload: TranscriptJSONValue?,
        seq: Int,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let keys = [
            "command", "cmd", "output", "stdout", "stderr", "aggregated_output",
            "formatted_output", "delta",
        ]
        for key in keys {
            guard let text = outputText(from: payload?[key]) else { continue }
            assembler.appendArtifactReferences(paths: artifactText.paths(in: text), seq: seq)
        }
    }
}
