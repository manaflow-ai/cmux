import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation

struct TranscriptActivityDetailModel: Equatable, Identifiable {
    struct ID: Equatable, Hashable, CustomStringConvertible {
        let sourceID: TranscriptRowID
        let ordinal: Int

        var description: String {
            "\(sourceID.description)#\(ordinal)"
        }
    }

    struct Section: Equatable, Identifiable {
        let id: String
        let label: Label
        let value: String
        let isCode: Bool
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

    let id: ID
    let sourceID: TranscriptRowID
    let kind: TranscriptActivityKind
    let title: String
    let sections: [Section]

    private static let maximumTitleCharacters = 180
    private static let maximumSectionCharacters = 40_000

    init(item: TranscriptActivityItem, ordinal: Int = 0) {
        id = ID(sourceID: item.id, ordinal: ordinal)
        sourceID = item.id
        kind = item.kind
        title = Self.title(for: item)
        guard let payload = item.sourceEntry?.content.payload else {
            sections = Self.compact([Self.text(.summary, item.summary)], fallback: title)
            return
        }
        sections = Self.sections(payload: payload, fallback: title)
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
            if nonempty(value.summary) == nil, let rawJSON = value.rawJSON {
                if let diagnostic = code(.diagnostic, rawJSON) {
                    sections.append(diagnostic)
                }
            }
            return sections
        }
    }

    private static func compact(_ candidates: [Section?], fallback: String) -> [Section] {
        let sections = candidates.compactMap(\.self)
        let resolved = sections.isEmpty ? [fallbackSection(fallback)] : sections
        return resolved.enumerated().map { index, section in
            Section(
                id: "\(index):\(section.label.rawValue)",
                label: section.label,
                value: boundedSectionValue(section.value),
                isCode: section.isCode
            )
        }
    }

    private static func text(_ label: Label, _ value: String?) -> Section? {
        guard let value = nonempty(value) else { return nil }
        return Section(id: label.rawValue, label: label, value: value, isCode: false)
    }

    private static func code(_ label: Label, _ value: String?) -> Section? {
        guard let value = nonempty(value) else { return nil }
        return Section(id: label.rawValue, label: label, value: value, isCode: true)
    }

    private static func fallbackSection(_ fallback: String) -> Section {
        Section(
            id: Label.summary.rawValue,
            label: .summary,
            value: boundedTitle(nonempty(fallback) ?? fallbackTitle()),
            isCode: false
        )
    }

    private static func title(for item: TranscriptActivityItem) -> String {
        boundedTitle(nonempty(item.summary)
            ?? nonempty(AgentGUIL10n.activityKind(item.kind))
            ?? fallbackTitle())
    }

    private static func fallbackTitle() -> String {
        AgentGUIL10n.string("agent.activity.details.title", defaultValue: "Activity")
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

    private static func boundedTitle(_ value: String) -> String {
        bounded(value, limit: maximumTitleCharacters, suffix: "…")
    }

    private static func boundedSectionValue(_ value: String) -> String {
        bounded(
            value,
            limit: maximumSectionCharacters,
            suffix: "\n\n\(AgentGUIL10n.activityDetailTruncated())"
        )
    }

    private static func bounded(_ value: String, limit: Int, suffix: String) -> String {
        guard limit > 0,
              let end = value.index(value.startIndex, offsetBy: limit, limitedBy: value.endIndex),
              end < value.endIndex
        else { return value }
        return String(value[..<end]) + suffix
    }
}
