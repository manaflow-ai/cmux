import Foundation

enum CodexSessionTitleParser {
    static let launchSource = "surface-title"

    private static let sessionSlugRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[^A-Z0-9_-])(codex-[0-9a-f]{8,}(?:-[A-Z0-9]+)+)(?=$|[^A-Z0-9_-])"#
    )

    static func sessionId(from title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = sessionSlugRegex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges > 1,
              let slugRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[slugRange])
    }

    static func restorableSnapshot(
        fromTitle title: String?,
        workingDirectory: String?
    ) -> SessionRestorableAgentSnapshot? {
        guard let sessionId = sessionId(from: title) else { return nil }
        let normalizedWorkingDirectory = normalized(workingDirectory)
        return SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: normalizedWorkingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: [
                    "codex",
                    "--dangerously-bypass-approvals-and-sandbox",
                ],
                workingDirectory: normalizedWorkingDirectory,
                environment: nil,
                capturedAt: nil,
                source: launchSource
            )
        )
    }

    static func isSurfaceTitleSnapshot(_ snapshot: SessionRestorableAgentSnapshot) -> Bool {
        snapshot.kind == .codex && snapshot.launchCommand?.source == launchSource
    }

    static func snapshot(_ snapshot: SessionRestorableAgentSnapshot, matchesTitle title: String?) -> Bool {
        isSurfaceTitleSnapshot(snapshot) && sessionId(from: title) == snapshot.sessionId
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
