import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation

struct TranscriptActivityDetailModel: Equatable {
    struct Section: Equatable, Identifiable {
        let label: Label
        let value: String
        let isCode: Bool

        var id: String { "\(label.rawValue):\(value)" }
    }

    enum Label: String, Equatable {
        case summary
        case thought
        case tool
        case arguments
        case command
        case result
        case output
        case status
        case duration
        case path
        case changes
        case diff
        case prompt
        case options
        case attachment
        case metadata
        case diagnostic
    }

    let title: String
    let sections: [Section]

    init(item: TranscriptActivityItem) {
        title = item.summary
        guard let payload = item.sourceEntry?.content.payload else {
            sections = [Section(label: .summary, value: item.summary, isCode: false)]
            return
        }
        sections = Self.sections(payload: payload, fallback: item.summary)
    }

    private static func sections(payload: EntryPayload, fallback: String) -> [Section] {
        switch payload {
        case .userMessage(let value):
            return compact([text(.prompt, value.text)], fallback: fallback)
        case .agentProse(let value):
            return compact([text(.summary, value.markdown)], fallback: fallback)
        case .thought(let value):
            return compact([text(.thought, value.text)], fallback: fallback)
        case .toolRun(let value):
            return compact([
                text(.tool, value.toolName),
                code(.arguments, value.inputDetail ?? value.argumentSummary),
                code(.command, value.command),
                text(.result, value.resultSummary),
                code(.output, value.output),
                text(.status, value.status ?? value.exitCode.map(exitCode)),
                text(.duration, value.durationSeconds.map(duration)),
            ], fallback: fallback)
        case .fileChange(let value):
            let path = [value.oldPath, value.newPath].compactMap(\.self).isEmpty
                ? value.path
                : [value.oldPath, value.newPath].compactMap(\.self).joined(separator: " → ")
            let counts = [
                value.additions.map { "+\($0)" },
                value.deletions.map { "-\($0)" },
            ].compactMap(\.self).joined(separator: "  ")
            return compact([
                text(.path, path),
                text(.changes, counts),
                text(.result, value.resultSummary),
                code(.diff, value.unifiedDiff),
            ], fallback: fallback)
        case .question(let value):
            return compact([
                text(.prompt, [value.header, value.prompt].compactMap(\.self).joined(separator: "\n")),
                text(.options, value.options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")),
                text(.result, value.answeredChoice.flatMap { value.options.indices.contains($0) ? value.options[$0] : nil }),
            ], fallback: fallback)
        case .permission(let value):
            return compact([
                text(.tool, value.toolName),
                text(.prompt, value.detail),
                text(.options, value.options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")),
            ], fallback: fallback)
        case .status(let value):
            return compact([
                text(.status, value.code.rawValue),
                text(.result, value.detail),
            ], fallback: fallback)
        case .attachment(let value):
            let dimensions: String? = if let width = value.width, let height = value.height {
                "\(width) × \(height)"
            } else {
                nil
            }
            return compact([
                text(.attachment, value.displayName ?? value.summary),
                text(.path, value.hostPath),
                text(.metadata, [
                    value.mimeType,
                    value.byteCount.map(byteCount),
                    dimensions,
                ].compactMap(\.self).joined(separator: " · ")),
            ], fallback: fallback)
        case .unknown(let value):
            var sections = compact([
                text(.summary, value.summary),
                text(.metadata, value.rawKind),
            ], fallback: fallback)
            if value.summary == nil, let rawJSON = value.rawJSON {
                if let diagnostic = code(.diagnostic, rawJSON) {
                    sections.append(diagnostic)
                }
            }
            return sections
        }
    }

    private static func compact(_ candidates: [Section?], fallback: String) -> [Section] {
        let sections = candidates.compactMap(\.self)
        return sections.isEmpty ? [text(.summary, fallback)!] : sections
    }

    private static func text(_ label: Label, _ value: String?) -> Section? {
        guard let value = nonempty(value) else { return nil }
        return Section(label: label, value: value, isCode: false)
    }

    private static func code(_ label: Label, _ value: String?) -> Section? {
        guard let value = nonempty(value) else { return nil }
        return Section(label: label, value: value, isCode: true)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func exitCode(_ value: Int) -> String {
        String(
            format: AgentGUIL10n.string(
                "agent.activity.detail.exitCodeFormat",
                defaultValue: "Exit %d"
            ),
            value
        )
    }

    private static func duration(_ value: Double) -> String {
        Measurement(value: value, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    private static func byteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}
