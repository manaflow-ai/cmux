import AppKit
import CodexTrajectory
import SwiftUI

struct CodexTrajectoryTranscriptView: NSViewRepresentable {
    var items: [CodexAppServerTranscriptItem]
    var bottomSpacerHeight: CGFloat = 184
    var transcriptFontSize: CGFloat = CGFloat(CodexAppServerUISettings.defaultTranscriptFontSize)

    func makeNSView(context: Context) -> CodexTrajectoryTranscriptScrollView {
        CodexTrajectoryTranscriptScrollView()
    }

    func updateNSView(_ nsView: CodexTrajectoryTranscriptScrollView, context: Context) {
#if DEBUG
        let start = CodexAppServerTiming.now()
#endif
        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: items)
#if DEBUG
        if items.count >= 100 {
            CodexAppServerTiming.log("transcript.entries", [
                "items": items.count,
                "entries": entries.count,
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
            ])
        } else {
            CodexAppServerTiming.logSlow("transcript.entries", start: start, thresholdMs: 5, [
                "items": items.count,
                "entries": entries.count,
            ])
        }
#endif
        nsView.update(
            entries: entries,
            bottomSpacerHeight: bottomSpacerHeight,
            transcriptFontSize: transcriptFontSize
        )
    }
}

enum CodexTrajectoryTranscriptDisplayKind: Hashable {
    case plain
    case toolGroup
    case toolRun
    case compaction
    case previousMessages
    case thinkingIndicator
    case reasoning
    case warning
}

private struct CodexTrajectoryFileChange: Hashable {
    var path: String
    var added: Int
    var removed: Int
}

struct CodexTrajectoryTranscriptDisplayEntry: Hashable {
    var id: String
    var kind: CodexTrajectoryTranscriptDisplayKind
    var title: String
    var subtitle: String
    var statusText: String?
    var block: CodexTrajectoryBlock
    fileprivate var toolRuns: [CodexTrajectoryToolRun] = []
    fileprivate var fileChanges: [CodexTrajectoryFileChange] = []
    fileprivate var previousEntries: [CodexTrajectoryTranscriptDisplayEntry] = []

    var isAccordion: Bool {
        kind == .toolGroup || kind == .toolRun || kind == .previousMessages
    }

    var isCompaction: Bool {
        kind == .compaction
    }

    var isPreviousMessages: Bool {
        kind == .previousMessages
    }

    var isThinkingIndicator: Bool {
        kind == .thinkingIndicator
    }

    var isUserMessage: Bool {
        block.kind == .userText
    }

    var isChatMessage: Bool {
        block.kind == .userText || block.kind == .assistantText
    }

    var containsChatMessage: Bool {
        if isChatMessage {
            return true
        }
        return previousEntries.contains { $0.containsChatMessage }
    }

    var streamingAssistantBlockIDs: [String] {
        var ids: [String] = []
        if block.kind == .assistantText, block.isStreaming {
            ids.append(block.id)
        }
        ids.append(contentsOf: previousEntries.flatMap(\.streamingAssistantBlockIDs))
        return ids
    }

    var accordionIDs: [String] {
        var ids: [String] = isAccordion ? [id] : []
        for entry in childToolRunEntries {
            ids.append(contentsOf: entry.accordionIDs)
        }
        for entry in previousEntries {
            ids.append(contentsOf: entry.accordionIDs)
        }
        return ids
    }

    var blockIDs: [String] {
        [block.id] + previousEntries.flatMap(\.blockIDs)
    }

    var toolSummaryLines: [String] {
        if kind == .toolGroup || kind == .toolRun {
            return []
        }
        let lines = toolRuns.map(\.summaryLine).filter { !$0.isEmpty }
        if !lines.isEmpty {
            return lines
        }
        return subtitle.isEmpty ? [] : [subtitle]
    }

    fileprivate var childToolRunEntries: [Self] {
        guard kind == .toolGroup else { return [] }
        return toolRuns.enumerated().map { index, run in
            Self.toolRun(run, index: index, parent: self)
        }
    }

    static func entries(from items: [CodexAppServerTranscriptItem]) -> [Self] {
        var entries: [Self] = []
        var toolItems: [CodexAppServerTranscriptItem] = []

        func flushToolItems() {
            guard !toolItems.isEmpty else { return }
            if let entry = toolGroup(from: toolItems) {
                entries.append(entry)
            }
            toolItems.removeAll(keepingCapacity: true)
        }

        for item in items {
            if item.isHiddenCodexLifecycleTranscriptItem {
                continue
            } else if item.isToolTranscriptItem {
                toolItems.append(item)
            } else if item.presentation == .compaction {
                flushToolItems()
                entries.append(compaction(from: item))
            } else if item.presentation == .thinkingIndicator {
                flushToolItems()
                entries.append(thinkingIndicator(from: item))
            } else if item.presentation == .reasoning {
                flushToolItems()
                entries.append(reasoning(from: item))
            } else if item.presentation == .warning {
                flushToolItems()
                entries.append(warning(from: item))
            } else {
                flushToolItems()
                entries.append(plain(from: item))
            }
        }
        flushToolItems()
        return collapsePreviousMessages(in: entries)
    }

    private static func collapsePreviousMessages(in entries: [Self]) -> [Self] {
        guard let latestUserIndex = entries.lastIndex(where: \.isUserMessage) else {
            return entries
        }

        guard let latestAssistantIndex = entries.indices.last(where: { index in
            index > latestUserIndex && entries[index].block.kind == .assistantText
        }) else {
            return entries
        }

        let progressStart = latestUserIndex + 1
        guard progressStart < latestAssistantIndex else {
            return entries
        }

        let previous = Array(entries[progressStart..<latestAssistantIndex])
        guard !previous.isEmpty else { return entries }
        guard previous.contains(where: \.containsChatMessage) else {
            return Array(entries[...latestUserIndex])
                + previous
                + Array(entries[latestAssistantIndex...])
        }

        return Array(entries[...latestUserIndex])
            + [previousMessages(previous, before: entries[latestAssistantIndex])]
            + Array(entries[latestAssistantIndex...])
    }

    private static func previousMessages(_ entries: [Self], before latest: Self) -> Self {
        let count = entries.count
        let title: String
        if count == 1 {
            title = String(localized: "codexAppServer.previousMessages.one", defaultValue: "1 previous message")
        } else {
            let format = String(
                localized: "codexAppServer.previousMessages.many",
                defaultValue: "%1$ld previous messages"
            )
            title = String(format: format, locale: Locale.current, count)
        }
        return Self(
            id: "previous-\(latest.id)",
            kind: .previousMessages,
            title: title,
            subtitle: "",
            statusText: nil,
            block: CodexTrajectoryBlock(
                id: "previous-\(latest.block.id)",
                kind: .status,
                title: title,
                text: "",
                isStreaming: false,
                createdAt: latest.block.createdAt
            ),
            previousEntries: entries
        )
    }

    private static func compaction(from item: CodexAppServerTranscriptItem) -> Self {
        Self(
            id: item.id.uuidString,
            kind: .compaction,
            title: item.title,
            subtitle: "",
            statusText: nil,
            block: CodexTrajectoryBlock(
                id: item.id.uuidString,
                kind: .status,
                title: item.title,
                text: "",
                isStreaming: false,
                createdAt: item.date
            )
        )
    }

    private static func thinkingIndicator(from item: CodexAppServerTranscriptItem) -> Self {
        Self(
            id: item.id.uuidString,
            kind: .thinkingIndicator,
            title: item.title,
            subtitle: item.body,
            statusText: nil,
            block: CodexTrajectoryBlock(
                id: item.id.uuidString,
                kind: .status,
                title: item.title,
                text: item.body,
                isStreaming: true,
                createdAt: item.date
            )
        )
    }

    private static func reasoning(from item: CodexAppServerTranscriptItem) -> Self {
        let text = reasoningDisplayText(item.body)
        return Self(
            id: item.id.uuidString,
            kind: .reasoning,
            title: "",
            subtitle: "",
            statusText: nil,
            block: CodexTrajectoryBlock(
                id: item.id.uuidString,
                kind: .status,
                title: "",
                text: text,
                isStreaming: item.isStreaming,
                createdAt: item.date
            )
        )
    }

    private static func reasoningDisplayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func warning(from item: CodexAppServerTranscriptItem) -> Self {
        Self(
            id: item.id.uuidString,
            kind: .warning,
            title: item.title,
            subtitle: "",
            statusText: nil,
            block: CodexTrajectoryBlock(
                id: item.id.uuidString,
                kind: .warning,
                title: item.title,
                text: item.body,
                isStreaming: item.isStreaming,
                createdAt: item.date
            )
        )
    }

    private static func plain(from item: CodexAppServerTranscriptItem) -> Self {
        let shouldSuppressRoleTitle: Bool
        switch item.role {
        case .user, .assistant:
            shouldSuppressRoleTitle = true
        case .event, .stderr, .error:
            shouldSuppressRoleTitle = false
        }
        let title = shouldSuppressRoleTitle ? "" : item.title
        return Self(
            id: item.id.uuidString,
            kind: .plain,
            title: title,
            subtitle: "",
            statusText: nil,
            block: CodexTrajectoryBlock(
                id: item.id.uuidString,
                kind: item.trajectoryKind,
                title: title,
                text: item.body,
                isStreaming: item.isStreaming,
                createdAt: item.date
            )
        )
    }

    private static func toolGroup(from items: [CodexAppServerTranscriptItem]) -> Self? {
        guard let first = items.first else { return nil }
        let runs = CodexTrajectoryToolRun.runs(from: items)
        guard !runs.isEmpty else { return nil }

        let title = CodexTrajectoryToolRun.title(for: runs)
        let summaryText = runs
            .map(\.summaryLine)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let subtitle = runs.compactMap(\.summary).first ?? first.title
        return Self(
            id: "toolgroup-\(first.id.uuidString)",
            kind: .toolGroup,
            title: title,
            subtitle: subtitle,
            statusText: statusText(for: runs),
            block: CodexTrajectoryBlock(
                id: "toolgroup-\(first.id.uuidString)-content",
                kind: .commandOutput,
                title: "",
                text: summaryText,
                isStreaming: items.contains(where: \.isStreaming),
                createdAt: first.date
            ),
            toolRuns: runs,
            fileChanges: runs.compactMap(\.fileChange)
        )
    }

    private static func toolRun(
        _ run: CodexTrajectoryToolRun,
        index: Int,
        parent: Self
    ) -> Self {
        let id = "\(parent.id)-run-\(index)"
        return Self(
            id: id,
            kind: .toolRun,
            title: run.summaryLine.isEmpty ? run.label : run.summaryLine,
            subtitle: run.summary ?? "",
            statusText: statusText(for: [run]),
            block: CodexTrajectoryBlock(
                id: "\(id)-content",
                kind: .commandOutput,
                title: "",
                text: run.detailText,
                isStreaming: parent.block.isStreaming,
                createdAt: parent.block.createdAt
            ),
            toolRuns: [run],
            fileChanges: run.fileChange.map { [$0] } ?? []
        )
    }

    private static func statusText(for runs: [CodexTrajectoryToolRun]) -> String? {
        let exitCodes = runs.compactMap(\.exitCode)
        guard !exitCodes.isEmpty else { return nil }
        if let failingCode = exitCodes.first(where: { $0 != 0 }) {
            let format = String(
                localized: "codexAppServer.toolGroup.exitCode",
                defaultValue: "Exit code %1$ld"
            )
            return String(format: format, locale: Locale.current, failingCode)
        }
        guard exitCodes.count == runs.count else { return nil }
        return String(localized: "codexAppServer.toolGroup.success", defaultValue: "Success")
    }
}

private enum CodexTrajectoryToolRunKind: Hashable {
    case command
    case edit
    case read
    case search
    case list
    case webSearch
    case hook
    case tool
}

private struct CodexTrajectoryToolRun: Hashable {
    var kind: CodexTrajectoryToolRunKind
    var label: String
    var summaryLine: String
    var command: String
    var output: String
    var exitCode: Int?
    var fileChange: CodexTrajectoryFileChange?

    var summary: String? {
        if !summaryLine.isEmpty {
            return summaryLine
        }
        return output.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    var detailText: String {
        let heading = summaryLine.isEmpty ? label : summaryLine
        var lines: [String] = [heading]
        if !command.isEmpty {
            let commandHeading = String(
                format: String(localized: "codexAppServer.toolGroup.ranCommandLine", defaultValue: "Ran %@"),
                locale: Locale.current,
                command
            )
            if heading != commandHeading {
                lines.append("")
                lines.append("$ \(command)")
            }
        }
        if !output.isEmpty {
            lines.append("")
            lines.append(output)
        }
        if let exitCode {
            lines.append("")
            let format = String(
                localized: "codexAppServer.toolGroup.exitCode",
                defaultValue: "Exit code %1$ld"
            )
            lines.append(String(format: format, locale: Locale.current, exitCode))
        }
        return lines.joined(separator: "\n")
    }

    static func runs(from items: [CodexAppServerTranscriptItem]) -> [Self] {
        var runs: [Self] = []
        for item in items {
            switch item.presentation {
            case .toolCall(let name):
                let newRuns = runsForToolCall(name: name, body: item.body, fallbackTitle: item.title)
                if let run = runs.last, run.command.isEmpty, !run.output.isEmpty {
                    if newRuns.count == 1 {
                        var merged = newRuns[0]
                        merged.output = run.output
                        merged.exitCode = run.exitCode
                        runs[runs.count - 1] = merged
                    } else {
                        runs.append(contentsOf: newRuns)
                    }
                    continue
                }
                runs.append(contentsOf: newRuns)
            case .toolOutput, .commandOutput:
                let normalized = CodexTrajectoryToolOutput.normalize(item.body)
                if runs.isEmpty {
                    runs.append(
                        Self(
                            kind: .tool,
                            label: item.title.isEmpty ? outputLabel : item.title,
                            summaryLine: item.title.isEmpty ? outputLabel : item.title,
                            command: "",
                            output: normalized.text,
                            exitCode: normalized.exitCode
                        )
                    )
                } else {
                    var run = runs.removeLast()
                    if !normalized.text.isEmpty {
                        if run.output.isEmpty {
                            run.output = normalized.text
                        } else {
                            run.output += "\n" + normalized.text
                        }
                    }
                    if let exitCode = normalized.exitCode {
                        run.exitCode = exitCode
                    }
                    runs.append(run)
                }
            case .hookEvent(let method):
                runs.append(hookRun(method: method, body: item.body, fallbackTitle: item.title))
            case .plain, .lifecycleEvent, .thinkingIndicator, .reasoning, .warning, .compaction:
                break
            }
        }
        return runs
    }

    static func title(for runs: [Self]) -> String {
        let editCount = count(.edit, in: runs)
        let commandCount = count(.command, in: runs)
        let readCount = count(.read, in: runs)
        let searchCount = count(.search, in: runs)
        let listCount = count(.list, in: runs)
        let webSearchCount = count(.webSearch, in: runs)
        let hookCount = count(.hook, in: runs)
        let toolCount = count(.tool, in: runs)

        var parts: [String] = []
        if editCount > 0 {
            parts.append(editCountTitle(editCount))
        }

        let hasExploration = readCount > 0 || searchCount > 0 || listCount > 0
        if hasExploration {
            let explorationParts = [
                readCount > 0 ? fileCountTitle(readCount) : nil,
                searchCount > 0 ? searchCountTitle(searchCount) : nil,
                listCount > 0 ? listCountTitle(listCount) : nil,
            ].compactMap { $0 }

            if editCount == 0 {
                let format = String(
                    localized: "codexAppServer.toolGroup.explored",
                    defaultValue: "Explored %@"
                )
                parts.append(
                    String(
                        format: format,
                        locale: Locale.current,
                        explorationParts.joined(separator: ", ")
                    )
                )
            } else {
                parts.append(contentsOf: explorationParts)
            }
        }

        if commandCount > 0 {
            parts.append(commandCountTitle(commandCount, isContinuation: !parts.isEmpty))
        }
        if webSearchCount > 0 {
            parts.append(webSearchCountTitle(webSearchCount, isContinuation: !parts.isEmpty))
        }
        if hookCount > 0 {
            parts.append(hookCountTitle(hookCount))
        }
        if toolCount > 0 {
            parts.append(toolCountTitle(toolCount))
        }

        guard !parts.isEmpty else {
            return String(localized: "codexAppServer.toolGroup.ranTool.one", defaultValue: "Ran tool")
        }
        return parts.joined(separator: ", ")
    }

    private static func runsForToolCall(name: String?, body: String, fallbackTitle: String) -> [Self] {
        let toolName = normalizedToolName(name ?? fallbackTitle)
        switch toolName {
        case "exec_command", "functions.exec_command", "shell", "command":
            return [shellRun(command: body, fallbackTitle: fallbackTitle)]
        case "apply_patch", "functions.apply_patch":
            return editRuns(from: body, fallbackTitle: fallbackTitle)
        case "web.run", "web":
            return webSearchRuns(from: body, fallbackTitle: fallbackTitle)
        case "tool_search.tool_search_tool", "tool_search_tool":
            return [toolSearchRun(from: body, fallbackTitle: fallbackTitle)]
        case "multi_tool_use.parallel":
            let nested = parallelToolRuns(from: body, fallbackTitle: fallbackTitle)
            return nested.isEmpty ? [genericToolRun(name: name, body: body, fallbackTitle: fallbackTitle)] : nested
        default:
            return [genericToolRun(name: name, body: body, fallbackTitle: fallbackTitle)]
        }
    }

    private static func shellRun(command: String, fallbackTitle: String) -> Self {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = shellTokens(from: trimmed)
        let executable = tokens.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""

        if isListCommand(executable: executable, tokens: tokens) {
            return Self(
                kind: .list,
                label: toolLabel(name: "shell", fallback: fallbackTitle),
                summaryLine: String(localized: "codexAppServer.toolGroup.listedFiles", defaultValue: "Listed files"),
                command: trimmed,
                output: "",
                exitCode: nil
            )
        }

        if isReadCommand(executable: executable),
           let path = fileArgument(from: tokens) {
            let format = String(
                localized: "codexAppServer.toolGroup.readFile",
                defaultValue: "Read %@"
            )
            return Self(
                kind: .read,
                label: toolLabel(name: "shell", fallback: fallbackTitle),
                summaryLine: String(format: format, locale: Locale.current, displayPath(path)),
                command: trimmed,
                output: "",
                exitCode: nil
            )
        }

        if isSearchCommand(executable: executable),
           let search = searchArguments(from: tokens) {
            let summary: String
            if let path = search.path, !path.isEmpty {
                let format = String(
                    localized: "codexAppServer.toolGroup.searchedForIn",
                    defaultValue: "Searched for %@ in %@"
                )
                summary = String(
                    format: format,
                    locale: Locale.current,
                    search.query,
                    displayPath(path)
                )
            } else {
                let format = String(
                    localized: "codexAppServer.toolGroup.searchedFor",
                    defaultValue: "Searched for %@"
                )
                summary = String(format: format, locale: Locale.current, search.query)
            }
            return Self(
                kind: .search,
                label: toolLabel(name: "shell", fallback: fallbackTitle),
                summaryLine: summary,
                command: trimmed,
                output: "",
                exitCode: nil
            )
        }

        let format = String(
            localized: "codexAppServer.toolGroup.ranCommandLine",
            defaultValue: "Ran %@"
        )
        return Self(
            kind: .command,
            label: toolLabel(name: "shell", fallback: fallbackTitle),
            summaryLine: String(format: format, locale: Locale.current, trimmed),
            command: trimmed,
            output: "",
            exitCode: nil
        )
    }

    private static func editRuns(from body: String, fallbackTitle: String) -> [Self] {
        let patchRuns = patchFileChanges(from: body).map { change in
            let format = String(
                localized: "codexAppServer.toolGroup.editedLine",
                defaultValue: "Edited %@ +%ld -%ld"
            )
            return Self(
                kind: .edit,
                label: toolLabel(name: "apply_patch", fallback: fallbackTitle),
                summaryLine: String(
                    format: format,
                    locale: Locale.current,
                    displayPath(change.path),
                    change.added,
                    change.removed
                ),
                command: body,
                output: "",
                exitCode: nil,
                fileChange: change
            )
        }
        if !patchRuns.isEmpty {
            return patchRuns
        }

        let paths = jsonPaths(from: body)
        if !paths.isEmpty {
            return paths.map { path in
                let format = String(
                    localized: "codexAppServer.toolGroup.editedLine",
                    defaultValue: "Edited %@ +%ld -%ld"
                )
                return Self(
                    kind: .edit,
                    label: toolLabel(name: "apply_patch", fallback: fallbackTitle),
                    summaryLine: String(format: format, locale: Locale.current, displayPath(path), 0, 0),
                    command: body,
                    output: "",
                    exitCode: nil,
                    fileChange: CodexTrajectoryFileChange(path: path, added: 0, removed: 0)
                )
            }
        }

        return [
            Self(
                kind: .edit,
                label: toolLabel(name: "apply_patch", fallback: fallbackTitle),
                summaryLine: String(localized: "codexAppServer.toolGroup.editedFiles", defaultValue: "Edited files"),
                command: body,
                output: "",
                exitCode: nil
            ),
        ]
    }

    private static func hookRun(method: String, body: String, fallbackTitle: String) -> Self {
        let object = jsonDictionary(from: body) ?? [:]
        let run = object["run"] as? [String: Any]
        let eventName = run.flatMap { stringValue(named: "eventName", in: $0) }
            ?? run.flatMap { stringValue(named: "event_name", in: $0) }
        let status = run.flatMap { stringValue(named: "status", in: $0) }
        let command = run.flatMap { stringValue(named: "command", in: $0) }
        let sourcePath = run.flatMap { stringValue(named: "sourcePath", in: $0) }
            ?? run.flatMap { stringValue(named: "source_path", in: $0) }
        let durationMs = run.flatMap { intValue(named: "durationMs", in: $0) }
            ?? run.flatMap { intValue(named: "duration_ms", in: $0) }
        let displayOrder = run.flatMap { intValue(named: "displayOrder", in: $0) }
            ?? run.flatMap { intValue(named: "display_order", in: $0) }
        let label = String(localized: "codexAppServer.hook.label", defaultValue: "Hook")

        let action: String
        switch method {
        case "hook/started":
            action = String(localized: "codexAppServer.hook.started", defaultValue: "Started")
        case "hook/completed":
            action = String(localized: "codexAppServer.hook.completed", defaultValue: "Completed")
        default:
            action = fallbackTitle.isEmpty ? method : fallbackTitle
        }

        let hookName = eventName?.isEmpty == false ? eventName! : method
        let summaryFormat = String(localized: "codexAppServer.hook.summary", defaultValue: "%@ hook %@")
        let summaryLine = String(format: summaryFormat, locale: Locale.current, action, hookName)

        var details: [String] = []
        if let command, !command.isEmpty {
            let format = String(localized: "codexAppServer.hook.command", defaultValue: "Command: %@")
            details.append(String(format: format, locale: Locale.current, command))
        }
        if let status, !status.isEmpty {
            let format = String(localized: "codexAppServer.hook.status", defaultValue: "Status: %@")
            details.append(String(format: format, locale: Locale.current, status))
        }
        if let durationMs {
            let format = String(localized: "codexAppServer.hook.duration", defaultValue: "Duration: %ld ms")
            details.append(String(format: format, locale: Locale.current, durationMs))
        }
        if let displayOrder {
            let format = String(localized: "codexAppServer.hook.order", defaultValue: "Order: %ld")
            details.append(String(format: format, locale: Locale.current, displayOrder))
        }
        if let sourcePath, !sourcePath.isEmpty {
            let format = String(localized: "codexAppServer.hook.source", defaultValue: "Source: %@")
            details.append(String(format: format, locale: Locale.current, displayPath(sourcePath)))
        }

        let threadId = stringValue(named: "threadId", in: object)
            ?? stringValue(named: "thread_id", in: object)
        if let threadId, !threadId.isEmpty {
            let format = String(localized: "codexAppServer.hook.thread", defaultValue: "Thread: %@")
            details.append(String(format: format, locale: Locale.current, threadId))
        }

        let output = details.isEmpty ? body.trimmingCharacters(in: .whitespacesAndNewlines) : details.joined(separator: "\n")
        return Self(
            kind: .hook,
            label: label,
            summaryLine: summaryLine,
            command: "",
            output: output,
            exitCode: nil
        )
    }

    private static func webSearchRuns(from body: String, fallbackTitle: String) -> [Self] {
        guard let object = jsonDictionary(from: body) else {
            return [genericToolRun(name: "web.run", body: body, fallbackTitle: fallbackTitle)]
        }
        let queries = queryStrings(from: object, key: "search_query")
            + queryStrings(from: object, key: "image_query")
        guard !queries.isEmpty else {
            return [genericToolRun(name: "web.run", body: body, fallbackTitle: fallbackTitle)]
        }
        return queries.map { query in
            Self(
                kind: .webSearch,
                label: toolLabel(name: "web.run", fallback: fallbackTitle),
                summaryLine: query,
                command: "",
                output: "",
                exitCode: nil
            )
        }
    }

    private static func toolSearchRun(from body: String, fallbackTitle: String) -> Self {
        let query = jsonDictionary(from: body).flatMap { stringValue(named: "query", in: $0) }
            ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = String(
            localized: "codexAppServer.toolGroup.searchedFor",
            defaultValue: "Searched for %@"
        )
        return Self(
            kind: .search,
            label: toolLabel(name: "tool_search_tool", fallback: fallbackTitle),
            summaryLine: String(format: format, locale: Locale.current, query),
            command: "",
            output: "",
            exitCode: nil
        )
    }

    private static func parallelToolRuns(from body: String, fallbackTitle: String) -> [Self] {
        guard let object = jsonDictionary(from: body),
              let toolUses = object["tool_uses"] as? [[String: Any]] else {
            return []
        }
        return toolUses.flatMap { toolUse -> [Self] in
            let name = stringValue(named: "recipient_name", in: toolUse)
                ?? stringValue(named: "name", in: toolUse)
            let parameters: Any = toolUse["parameters"] ?? toolUse["input"] ?? [String: Any]()
            let body: String
            if let value = parameters as? String {
                body = value
            } else if let object = parameters as? [String: Any] {
                if let command = stringValue(named: "cmd", in: object)
                    ?? stringValue(named: "command", in: object) {
                    body = command
                } else {
                    body = prettyJSON(object)
                }
            } else {
                body = String(describing: parameters)
            }
            return runsForToolCall(name: name, body: body, fallbackTitle: name ?? fallbackTitle)
        }
    }

    private static func genericToolRun(name: String?, body: String, fallbackTitle: String) -> Self {
        let label = toolLabel(name: name, fallback: fallbackTitle)
        let format = String(
            localized: "codexAppServer.toolGroup.usedTool",
            defaultValue: "Used %@"
        )
        return Self(
            kind: .tool,
            label: label,
            summaryLine: String(format: format, locale: Locale.current, label),
            command: body,
            output: "",
            exitCode: nil
        )
    }

    private static var outputLabel: String {
        String(localized: "codexAppServer.toolGroup.output", defaultValue: "Output")
    }

    private static func toolLabel(name: String?, fallback: String) -> String {
        let rawCandidate: String
        if let name, !name.isEmpty {
            rawCandidate = name
        } else {
            rawCandidate = fallback
        }
        let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate == "exec_command" || candidate == "shell" || candidate == "Command" {
            return String(localized: "codexAppServer.toolGroup.shell", defaultValue: "Shell")
        }
        return candidate.isEmpty ? outputLabel : candidate
    }

    private static func normalizedToolName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func count(_ kind: CodexTrajectoryToolRunKind, in runs: [Self]) -> Int {
        runs.filter { $0.kind == kind }.count
    }

    private static func editCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "codexAppServer.toolGroup.editedFile.one", defaultValue: "Edited 1 file")
        }
        let format = String(
            localized: "codexAppServer.toolGroup.editedFile.many",
            defaultValue: "Edited %1$ld files"
        )
        return String(format: format, locale: Locale.current, count)
    }

    private static func fileCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "codexAppServer.toolGroup.file.one", defaultValue: "1 file")
        }
        let format = String(
            localized: "codexAppServer.toolGroup.file.many",
            defaultValue: "%1$ld files"
        )
        return String(format: format, locale: Locale.current, count)
    }

    private static func searchCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "codexAppServer.toolGroup.search.one", defaultValue: "1 search")
        }
        let format = String(
            localized: "codexAppServer.toolGroup.search.many",
            defaultValue: "%1$ld searches"
        )
        return String(format: format, locale: Locale.current, count)
    }

    private static func listCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "codexAppServer.toolGroup.list.one", defaultValue: "1 list")
        }
        let format = String(
            localized: "codexAppServer.toolGroup.list.many",
            defaultValue: "%1$ld lists"
        )
        return String(format: format, locale: Locale.current, count)
    }

    private static func commandCountTitle(_ count: Int, isContinuation: Bool) -> String {
        if count == 1 {
            return isContinuation
                ? String(localized: "codexAppServer.toolGroup.ranCommand.one.continuation", defaultValue: "ran command")
                : String(localized: "codexAppServer.toolGroup.ranCommand.one", defaultValue: "Ran command")
        }
        let format = isContinuation
            ? String(
                localized: "codexAppServer.toolGroup.ranCommand.many.continuation",
                defaultValue: "ran %1$ld commands"
            )
            : String(localized: "codexAppServer.toolGroup.ranCommand.many", defaultValue: "Ran %1$ld commands")
        return String(format: format, locale: Locale.current, count)
    }

    private static func webSearchCountTitle(_ count: Int, isContinuation: Bool) -> String {
        if count == 1 {
            return isContinuation
                ? String(localized: "codexAppServer.toolGroup.searchedWeb.one.continuation", defaultValue: "searched web")
                : String(localized: "codexAppServer.toolGroup.searchedWeb.one.start", defaultValue: "Searched web")
        }
        let format = isContinuation
            ? String(
                localized: "codexAppServer.toolGroup.searchedWeb.many.continuation",
                defaultValue: "searched web %1$ld times"
            )
            : String(
                localized: "codexAppServer.toolGroup.searchedWeb.many.start",
                defaultValue: "Searched web %1$ld times"
            )
        return String(format: format, locale: Locale.current, count)
    }

    private static func hookCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "codexAppServer.hook.count.one", defaultValue: "Hook event")
        }
        let format = String(
            localized: "codexAppServer.hook.count.many",
            defaultValue: "%1$ld hook events"
        )
        return String(format: format, locale: Locale.current, count)
    }

    private static func toolCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "codexAppServer.toolGroup.ranTool.one", defaultValue: "Ran tool")
        }
        let format = String(
            localized: "codexAppServer.toolGroup.ranTool.many",
            defaultValue: "Ran %1$ld tools"
        )
        return String(format: format, locale: Locale.current, count)
    }

    private static func isReadCommand(executable: String) -> Bool {
        ["cat", "sed", "nl", "head", "tail"].contains(executable)
    }

    private static func isSearchCommand(executable: String) -> Bool {
        ["rg", "grep", "ag"].contains(executable)
    }

    private static func isListCommand(executable: String, tokens: [String]) -> Bool {
        if ["ls", "find", "fd"].contains(executable) {
            return true
        }
        if executable == "rg", tokens.contains("--files") {
            return true
        }
        if executable == "git", tokens.dropFirst().first == "ls-files" {
            return true
        }
        return false
    }

    private static func shellTokens(from command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    private static func fileArgument(from tokens: [String]) -> String? {
        for token in tokens.dropFirst().reversed() {
            guard !token.hasPrefix("-"),
                  token != "|",
                  token != ">",
                  token != "2>",
                  token != "1>" else {
                continue
            }
            return token
        }
        return nil
    }

    private static func searchArguments(from tokens: [String]) -> (query: String, path: String?)? {
        guard tokens.count > 1 else { return nil }
        var arguments: [String] = []
        var shouldSkipNext = false
        let optionsWithValues: Set<String> = [
            "-e", "-f", "-g", "--glob", "--type", "-t", "--type-not", "-T", "--context", "-C",
            "--after-context", "-A", "--before-context", "-B",
        ]

        for token in tokens.dropFirst() {
            if shouldSkipNext {
                shouldSkipNext = false
                continue
            }
            if optionsWithValues.contains(token) {
                shouldSkipNext = true
                continue
            }
            if token.hasPrefix("-") {
                continue
            }
            arguments.append(token)
        }
        guard let query = arguments.first else { return nil }
        return (query, arguments.dropFirst().last)
    }

    private static func patchFileChanges(from body: String) -> [CodexTrajectoryFileChange] {
        var changes: [CodexTrajectoryFileChange] = []
        var current: CodexTrajectoryFileChange?

        func finishCurrent() {
            if let current {
                changes.append(current)
            }
            current = nil
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let path = patchPath(from: line) {
                finishCurrent()
                current = CodexTrajectoryFileChange(path: path, added: 0, removed: 0)
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                current?.added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                current?.removed += 1
            }
        }
        finishCurrent()
        return changes
    }

    private static func patchPath(from line: String) -> String? {
        let prefixes = [
            "*** Update File: ",
            "*** Add File: ",
            "*** Delete File: ",
        ]
        for prefix in prefixes where line.hasPrefix(prefix) {
            let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        return nil
    }

    private static func jsonPaths(from body: String) -> [String] {
        guard let value = jsonValue(from: body) else { return [] }
        var paths: [String] = []

        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if ["path", "file", "filePath", "filename"].contains(key),
                       let string = child as? String,
                       !string.isEmpty {
                        paths.append(string)
                    }
                    collect(child)
                }
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }

        collect(value)
        return Array(Set(paths)).sorted()
    }

    private static func queryStrings(from object: [String: Any], key: String) -> [String] {
        guard let queries = object[key] as? [[String: Any]] else { return [] }
        return queries.compactMap { query in
            stringValue(named: "q", in: query)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    fileprivate static func displayPath(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("./") {
            path.removeFirst(2)
        }
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func jsonDictionary(from text: String) -> [String: Any]? {
        jsonValue(from: text) as? [String: Any]
    }

    private static func jsonValue(from text: String) -> Any? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func stringValue(named key: String, in object: [String: Any]) -> String? {
        if let value = object[key] as? String {
            return value
        }
        if let value = object[key] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func intValue(named key: String, in object: [String: Any]) -> Int? {
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.intValue
        }
        if let value = object[key] as? String {
            return Int(value)
        }
        return nil
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}

private struct CodexTrajectoryToolOutput {
    var text: String
    var exitCode: Int?

    static func normalize(_ body: String) -> Self {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self(text: trimmed, exitCode: nil)
        }

        let stdout = stringValue(named: "stdout", in: object)
            ?? stringValue(named: "output", in: object)
            ?? stringValue(named: "text", in: object)
        let stderr = stringValue(named: "stderr", in: object)
        let parts = [stdout, stderr]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let displayText = parts.isEmpty ? prettyJSON(object) : parts.joined(separator: "\n")
        return Self(
            text: displayText,
            exitCode: intValue(named: "exit_code", in: object)
                ?? intValue(named: "exitCode", in: object)
                ?? intValue(named: "status", in: object)
        )
    }

    private static func stringValue(named key: String, in object: [String: Any]) -> String? {
        if let value = object[key] as? String {
            return value
        }
        if let value = object[key] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func intValue(named key: String, in object: [String: Any]) -> Int? {
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? NSNumber {
            return value.intValue
        }
        if let value = object[key] as? String {
            return Int(value)
        }
        return nil
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}

private extension CodexAppServerTranscriptItem {
    var isToolTranscriptItem: Bool {
        switch presentation {
        case .toolCall, .toolOutput, .commandOutput, .hookEvent:
            return true
        case .plain, .lifecycleEvent, .thinkingIndicator, .reasoning, .warning, .compaction:
            return false
        }
    }

    var isHiddenCodexLifecycleTranscriptItem: Bool {
        guard role == .event else { return false }
        if presentation == .lifecycleEvent {
            return true
        }
        guard presentation == .plain else { return false }
        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyText = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let quietMethods: Set<String> = [
            "mcpServer/startupStatus/updated",
            "remoteControl/status/changed",
            "thread/status/changed",
            "thread/tokenUsage/updated",
        ]
        if quietMethods.contains(titleText) {
            return true
        }

        let quietBodies: Set<String> = [
            "idle",
            "running",
        ]
        return quietBodies.contains(bodyText) && titleText.hasPrefix("thread/")
    }

    var trajectoryKind: CodexTrajectoryBlockKind {
        switch role {
        case .user:
            return .userText
        case .assistant:
            return .assistantText
        case .event:
            if presentation == .warning {
                return .warning
            }
            return .systemEvent
        case .stderr:
            return .stderr
        case .error:
            return .stderr
        }
    }
}

final class CodexTrajectoryTranscriptScrollView: NSScrollView {
    private let trajectoryView = CodexTrajectoryTranscriptDocumentView()
    private var entries: [CodexTrajectoryTranscriptDisplayEntry] = []
    private var bottomSpacerHeight: CGFloat = 184
    private var transcriptFontSize: CGFloat = CGFloat(CodexAppServerUISettings.defaultTranscriptFontSize)
    private var backgroundObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        backgroundColor = .clear
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        contentView.drawsBackground = false
        contentView.backgroundColor = .clear
        contentInsets = NSEdgeInsets(top: 18, left: 0, bottom: 0, right: 0)
        documentView = trajectoryView
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshThemeColors()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    override func layout() {
        super.layout()
        reloadPreservingScroll(stickToBottom: isScrolledNearBottom, animateScroll: false)
    }

    fileprivate func update(
        entries: [CodexTrajectoryTranscriptDisplayEntry],
        bottomSpacerHeight: CGFloat,
        transcriptFontSize: CGFloat
    ) {
        let shouldStickToBottom = isScrolledNearBottom
        let normalizedBottomSpacerHeight = max(0, bottomSpacerHeight)
        let spacerChanged = abs(normalizedBottomSpacerHeight - self.bottomSpacerHeight) > 0.5
        let normalizedFontSize = CodexAppServerUISettings.clampedTranscriptFontSize(Double(transcriptFontSize))
        let fontSizeChanged = abs(normalizedFontSize - self.transcriptFontSize) > 0.1
        self.entries = entries
        self.bottomSpacerHeight = normalizedBottomSpacerHeight
        self.transcriptFontSize = normalizedFontSize
        reloadPreservingScroll(stickToBottom: shouldStickToBottom, animateScroll: spacerChanged || fontSizeChanged)
    }

    private var documentWidth: CGFloat {
        max(1, contentView.bounds.width)
    }

    private var isScrolledNearBottom: Bool {
        let visibleMaxY = contentView.bounds.maxY
        return trajectoryView.frame.height - visibleMaxY < 48
    }

    private func reloadPreservingScroll(stickToBottom: Bool, animateScroll: Bool) {
        guard documentWidth > 1 else { return }
#if DEBUG
        let start = CodexAppServerTiming.now()
#endif
        trajectoryView.update(
            entries: entries,
            width: documentWidth,
            bottomSpacerHeight: bottomSpacerHeight,
            transcriptFontSize: transcriptFontSize
        )
        if stickToBottom {
            scrollToBottom(animated: animateScroll)
        }
#if DEBUG
        if entries.count >= 100 {
            CodexAppServerTiming.log("transcript.scrollUpdate", [
                "entries": entries.count,
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
                "stick": stickToBottom,
                "animate": animateScroll,
                "width": Int(documentWidth),
            ])
        } else {
            CodexAppServerTiming.logSlow("transcript.scrollUpdate", start: start, thresholdMs: 8, [
                "entries": entries.count,
                "stick": stickToBottom,
                "animate": animateScroll,
                "width": Int(documentWidth),
            ])
        }
#endif
    }

    private func refreshThemeColors() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        trajectoryView.invalidateTheme()
    }

    private func scrollToBottom(animated: Bool) {
        let maxY = max(0, trajectoryView.frame.height - contentView.bounds.height)
        let targetOrigin = NSPoint(x: 0, y: maxY)
        if animated, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                contentView.animator().setBoundsOrigin(targetOrigin)
            } completionHandler: {
                self.reflectScrolledClipView(self.contentView)
            }
        } else {
            contentView.scroll(to: targetOrigin)
            reflectScrolledClipView(contentView)
        }
    }
}

struct CodexStreamingFadeState: Equatable {
    private(set) var startTimes: [String: TimeInterval] = [:]
    private(set) var completedIDs: Set<String> = []

    var hasActiveFades: Bool {
        !startTimes.isEmpty
    }

    mutating func updateActiveStreamingIDs(_ activeIDs: Set<String>, now: TimeInterval) {
        completedIDs.formIntersection(activeIDs)
        startTimes = startTimes.filter { activeIDs.contains($0.key) }
        for id in activeIDs where startTimes[id] == nil && !completedIDs.contains(id) {
            startTimes[id] = now
        }
    }

    mutating func pruneExpired(now: TimeInterval, duration: TimeInterval) {
        startTimes = startTimes.filter { id, start in
            guard now - start >= duration else { return true }
            completedIDs.insert(id)
            return false
        }
    }

    func alpha(for id: String, now: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard let start = startTimes[id] else { return 1 }
        let progress = min(1, max(0, (now - start) / duration))
        return 0.24 + CGFloat(progress) * 0.76
    }
}

private final class CodexTrajectoryTranscriptDocumentView: NSView, NSUserInterfaceValidations {
    private enum PageChrome {
        case plain
        case accordionHeader
        case accordionContent
        case fileChangeCard
        case compaction
        case previousMessagesHeader
        case thinkingIndicator
        case bottomSpacer
    }

    private struct PageEntry {
        var entry: CodexTrajectoryTranscriptDisplayEntry
        var page: CodexTrajectoryLayoutPage?
        var chrome: PageChrome
        var topSpacing: CGFloat
        var bottomSpacing: CGFloat
        var fullContentHeight: CGFloat
    }

    private struct LayoutCacheKey: Hashable {
        var block: CodexTrajectoryBlock
        var width: Int
        var themeIdentifier: String
    }

    private struct CachedLayout {
        var block: CodexTrajectoryBlock
        var layout: CodexTrajectoryBlockLayout
    }

    private struct TextSelectionEndpoint: Equatable {
        var blockID: String
        var utf16Offset: Int
    }

    private struct TextSelection {
        var anchor: TextSelectionEndpoint
        var focus: TextSelectionEndpoint

        var isEmpty: Bool {
            anchor == focus
        }
    }

    private struct NormalizedTextSelection {
        var lower: TextSelectionEndpoint
        var upper: TextSelectionEndpoint
        var lowerBlockIndex: Int
        var upperBlockIndex: Int
    }

    private struct MessageHoverKey: Hashable {
        var blockID: String
        var pageIndex: Int
    }

    private enum MessageChromeZone {
        case message
        case metadata
        case copy
    }

    private struct MessageChromeSnapshot {
        var key: MessageHoverKey
        var entry: CodexTrajectoryTranscriptDisplayEntry
        var pageRect: CGRect
        var accessoryRowRect: CGRect
        var metadataRect: CGRect
        var timestampRect: CGRect?
        var timestampText: String
        var copyRect: CGRect
        var copyHitRect: CGRect

        func zone(at point: CGPoint) -> MessageChromeZone? {
            if copyHitRect.contains(point) {
                return .copy
            }
            if metadataRect.contains(point) {
                return .metadata
            }
            if pageRect.contains(point) || accessoryRowRect.contains(point) {
                return .message
            }
            return nil
        }
    }

    private struct MessageHoverHit {
        var snapshot: MessageChromeSnapshot
        var zone: MessageChromeZone

        var key: MessageHoverKey {
            snapshot.key
        }

        var entry: CodexTrajectoryTranscriptDisplayEntry {
            snapshot.entry
        }
    }

    private enum CodexTranscriptCopyIconButton {
        static let size = CGSize(width: 22, height: 22)

        static func draw(
            in rect: CGRect,
            isHovering: Bool,
            isPressed: Bool,
            isCopied: Bool,
            appearance: NSAppearance,
            context: CGContext
        ) {
            let palette = CodexAppServerAdaptivePalette(appearance: appearance)
            let showsBackground = isHovering || isPressed || isCopied
            let fill: NSColor
            if isPressed {
                fill = palette.overlayButtonActiveFill
            } else if isHovering || isCopied {
                fill = palette.overlayButtonHoverFill
            } else {
                fill = palette.overlayButtonFill
            }
            let glyphColor: NSColor
            if isCopied {
                let success = CodexTrajectoryTranscriptDocumentView.color(.systemGreen, appearance: appearance)
                glyphColor = abs(success.luminance - fill.luminance) > 0.32
                    ? success
                    : palette.overlayButtonHoverGlyph
            } else if isPressed {
                glyphColor = palette.overlayButtonActiveGlyph
            } else if isHovering {
                glyphColor = palette.overlayButtonHoverGlyph
            } else {
                glyphColor = palette.secondaryText
            }

            context.saveGState()
            if showsBackground {
                context.setFillColor(fill.cgColor)
                context.addEllipse(in: rect)
                context.fillPath()
            }

            if isCopied {
                drawCheckGlyph(in: rect, color: glyphColor.cgColor, context: context)
            } else {
                drawClipboardGlyph(in: rect, color: glyphColor.cgColor, context: context)
            }
            context.restoreGState()
        }

        private static func drawClipboardGlyph(in rect: CGRect, color: CGColor, context: CGContext) {
            context.setStrokeColor(color)
            context.setLineWidth(1.45)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let board = CGRect(x: rect.midX - 5.0, y: rect.midY - 4.5, width: 10.0, height: 11.0)
            let clip = CGRect(x: rect.midX - 3.2, y: rect.midY - 6.2, width: 6.4, height: 3.8)
            context.addPath(CGPath(roundedRect: board, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
            context.strokePath()
            context.addPath(CGPath(roundedRect: clip, cornerWidth: 1.8, cornerHeight: 1.8, transform: nil))
            context.strokePath()

            context.setLineWidth(1.05)
            context.move(to: CGPoint(x: board.minX + 2.6, y: board.midY + 0.8))
            context.addLine(to: CGPoint(x: board.maxX - 2.6, y: board.midY + 0.8))
            context.move(to: CGPoint(x: board.minX + 2.6, y: board.midY + 3.3))
            context.addLine(to: CGPoint(x: board.maxX - 2.6, y: board.midY + 3.3))
            context.strokePath()
        }

        private static func drawCheckGlyph(in rect: CGRect, color: CGColor, context: CGContext) {
            context.setStrokeColor(color)
            context.setLineWidth(1.65)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: rect.midX - 4.8, y: rect.midY + 0.1))
            context.addLine(to: CGPoint(x: rect.midX - 1.4, y: rect.midY + 3.5))
            context.addLine(to: CGPoint(x: rect.midX + 5.2, y: rect.midY - 4.3))
            context.strokePath()
        }
    }

    private enum AccordionChrome {
        static let chevronTextGap: CGFloat = 11
        static let toolRunLeadingInset: CGFloat = 19
        static let toolRunChevronX: CGFloat = 6.5
        static let titleChevronY: CGFloat = 13
        static let chevronLineWidth: CGFloat = 1.35

        static func drawChevron(
            progress: CGFloat,
            center: CGPoint,
            color: CGColor,
            context: CGContext
        ) {
            let clampedProgress = min(1, max(0, progress))
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: CGFloat.pi / 2 * clampedProgress)
            context.setStrokeColor(color)
            context.setLineWidth(chevronLineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: -2.6, y: -3.8))
            context.addLine(to: CGPoint(x: 2.4, y: 0))
            context.addLine(to: CGPoint(x: -2.6, y: 3.8))
            context.strokePath()
            context.restoreGState()
        }
    }

    private struct AccordionAnimation {
        var startTime: TimeInterval
        var from: CGFloat
        var to: CGFloat
    }

    private let layoutEngine = CodexTrajectoryLayoutEngine()
    private let renderer = CodexTrajectoryRenderer()
    private var entries: [CodexTrajectoryTranscriptDisplayEntry] = []
    private var pageEntries: [PageEntry] = []
    private var heightIndex = CodexTrajectoryHeightIndex()
    private var messageChromeSnapshotsByPageEntryIndex: [Int: MessageChromeSnapshot] = [:]
    private var cachedLayouts: [LayoutCacheKey: CachedLayout] = [:]
    private var activeLayoutCacheKeys: Set<LayoutCacheKey> = []
    private var expandedAccordionIDs: Set<String> = []
    private var accordionAnimations: [String: AccordionAnimation] = [:]
    private var accordionAnimationTimer: Timer?
#if DEBUG
    private var debugLayoutRequestCount = 0
    private var debugLayoutCacheHitCount = 0
#endif
    private var textSelection: TextSelection?
    private var isSelectingText = false
    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredMessageKey: MessageHoverKey?
    private var hoveredCopyKey: MessageHoverKey?
    private var pressedCopyKey: MessageHoverKey?
    private var copiedMessageKey: MessageHoverKey?
    private var copiedIconResetTimer: Timer?
    private let messageHoverFadeDuration: TimeInterval = 0.14
    private var messageHoverFadeStartTimes: [MessageHoverKey: TimeInterval] = [:]
    private var messageHoverFadeTimer: Timer?
    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    private var documentWidth: CGFloat = 1
    private let horizontalInset: CGFloat = 24
    private let maxContentWidth: CGFloat = 860
    private let maxUserBubbleWidth: CGFloat = 860
    private let transcriptTopSpacerHeight: CGFloat = 30
    private let rowSpacing: CGFloat = 15
    private let plainChatTopSpacing: CGFloat = 4
    private let messageAccessoryTopGap: CGFloat = 10
    private let messageAccessoryBottomGap: CGFloat = 8
    private let messageAccessoryHorizontalRetention: CGFloat = 14
    private let messageAccessoryVerticalRetention: CGFloat = 4
    private var messageAccessoryHeight: CGFloat {
        CodexTranscriptCopyIconButton.size.height
    }
    private var plainChatBottomSpacing: CGFloat {
        messageAccessoryTopGap + messageAccessoryHeight + messageAccessoryBottomGap
    }
    private let accordionHeaderTitleHeight: CGFloat = 28
    private let accordionSummaryRowHeight: CGFloat = 23
    private let accordionSummaryLimit = 12
    private let accordionAnimationDuration: TimeInterval = 0.16
    private let previousMessagesHeaderHeight: CGFloat = 46
    private let compactionHeight: CGFloat = 58
    private let thinkingIndicatorHeight: CGFloat = 32
    private let accordionContentIndent: CGFloat = 0
    private let accordionContentTopSpacing: CGFloat = 2
    private let fileChangeHeaderHeight: CGFloat = 44
    private let fileChangeRowHeight: CGFloat = 40
    private var bottomSpacerHeight: CGFloat = 184
    private var transcriptFontSize: CGFloat = CGFloat(CodexAppServerUISettings.defaultTranscriptFontSize)
    private let streamingFadeDuration: TimeInterval = 0.18
    private var streamingFadeState = CodexStreamingFadeState()
    private var streamingFadeTimer: Timer?
    private var thinkingAnimationStartTime = ProcessInfo.processInfo.systemUptime
    private var thinkingAnimationTimer: Timer?

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        false
    }

    override var isOpaque: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    deinit {
        accordionAnimationTimer?.invalidate()
        streamingFadeTimer?.invalidate()
        thinkingAnimationTimer?.invalidate()
        copiedIconResetTimer?.invalidate()
        messageHoverFadeTimer?.invalidate()
    }

    func update(
        entries: [CodexTrajectoryTranscriptDisplayEntry],
        width: CGFloat,
        bottomSpacerHeight: CGFloat,
        transcriptFontSize: CGFloat
    ) {
#if DEBUG
        let start = CodexAppServerTiming.now()
#endif
        let normalizedWidth = max(1, width)
        let normalizedBottomSpacerHeight = max(0, bottomSpacerHeight)
        let normalizedFontSize = CodexAppServerUISettings.clampedTranscriptFontSize(Double(transcriptFontSize))
        let activeAccordionIDs = Set(entries.flatMap(\.accordionIDs))
        expandedAccordionIDs.formIntersection(activeAccordionIDs)
        accordionAnimations = accordionAnimations.filter { activeAccordionIDs.contains($0.key) }

        let oldContentWidth = contentWidth
        let widthChanged = abs(normalizedWidth - documentWidth) > 0.5
        let entriesChanged = entries != self.entries
        let bottomSpacerChanged = abs(normalizedBottomSpacerHeight - self.bottomSpacerHeight) > 0.5
        let fontSizeChanged = abs(normalizedFontSize - self.transcriptFontSize) > 0.1
        updateStreamingFadeState(for: entries)
        updateThinkingAnimationState(for: entries)
        guard entriesChanged || widthChanged || bottomSpacerChanged || fontSizeChanged else { return }

        if bottomSpacerChanged, !entriesChanged, !widthChanged, !fontSizeChanged, updateExistingBottomSpacerHeight(normalizedBottomSpacerHeight) {
#if DEBUG
            CodexAppServerTiming.logSlow("transcript.documentUpdate.spacerOnly", start: start, thresholdMs: 2, [
                "entries": entries.count,
                "spacer": Int(normalizedBottomSpacerHeight),
            ])
#endif
            return
        }

        self.entries = entries
        documentWidth = normalizedWidth
        self.bottomSpacerHeight = normalizedBottomSpacerHeight
        self.transcriptFontSize = normalizedFontSize

        let contentWidthChanged = abs(contentWidth - oldContentWidth) > 0.5
        if entriesChanged || contentWidthChanged || fontSizeChanged || pageEntries.isEmpty {
            rebuildLayout()
        } else {
            if widthChanged {
                rebuildMessageChromeSnapshots()
            }
            setFrameSize(NSSize(width: documentWidth, height: max(1, heightIndex.totalHeight)))
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
#if DEBUG
        if entries.count >= 100 {
            CodexAppServerTiming.log("transcript.documentUpdate", [
                "entries": entries.count,
                "pages": pageEntries.count,
                "height": Int(heightIndex.totalHeight),
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
                "entries_changed": entriesChanged,
                "width_changed": widthChanged,
                "spacer_changed": bottomSpacerChanged,
                "font_size_changed": fontSizeChanged,
            ])
        } else {
            CodexAppServerTiming.logSlow("transcript.documentUpdate", start: start, thresholdMs: 8, [
                "entries": entries.count,
                "pages": pageEntries.count,
                "height": Int(heightIndex.totalHeight),
                "entries_changed": entriesChanged,
                "width_changed": widthChanged,
                "spacer_changed": bottomSpacerChanged,
            ])
        }
#endif
    }

    private func updateExistingBottomSpacerHeight(_ height: CGFloat) -> Bool {
        guard !pageEntries.isEmpty,
              pageEntries[pageEntries.count - 1].chrome == .bottomSpacer else {
            self.bottomSpacerHeight = height
            return false
        }
        bottomSpacerHeight = height
        let lastIndex = pageEntries.count - 1
        pageEntries[lastIndex].fullContentHeight = height
        heightIndex.update(index: lastIndex, height: height)
        setFrameSize(NSSize(width: documentWidth, height: max(1, heightIndex.totalHeight)))
        return true
    }

    fileprivate func invalidateTheme() {
        cachedLayouts.removeAll(keepingCapacity: true)
        rebuildLayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let range = heightIndex.indexRange(
            intersectingOffset: dirtyRect.minY,
            length: dirtyRect.height,
            overscan: 480
        )
        guard !range.isEmpty else { return }

        let theme = currentTheme
        for index in range {
            let y = heightIndex.prefixSum(upTo: index)
            let pageEntry = pageEntries[index]
            switch pageEntry.chrome {
            case .plain:
                guard let page = pageEntry.page else { continue }
                let pageRect = plainPageRect(for: pageEntry, page: page, at: y)
                drawBackground(for: pageEntry.entry.block.kind, in: pageRect, context: context)
                drawSelectionIfNeeded(
                    pageEntry: pageEntry,
                    pageEntryIndex: index,
                    page: page,
                    pageRect: pageRect,
                    theme: theme,
                    context: context
                )
                context.saveGState()
                context.setAlpha(streamingAlpha(for: pageEntry.entry))
                renderer.draw(
                    block: pageEntry.entry.block,
                    page: page,
                    in: context,
                    rect: pageRect,
                    theme: theme,
                    coordinates: .yDown
                )
                context.restoreGState()
            case .accordionHeader:
                let rect = accordionHeaderRect(for: pageEntry.entry, at: y)
                drawAccordionHeader(entry: pageEntry.entry, in: rect, context: context)
            case .previousMessagesHeader:
                let rect = accordionHeaderRect(for: pageEntry.entry, at: y)
                drawPreviousMessagesHeader(entry: pageEntry.entry, in: rect, context: context)
            case .accordionContent:
                guard let page = pageEntry.page else { continue }
                let allocatedHeight = heightIndex.height(at: index) ?? 0
                guard allocatedHeight > 0.5 else { continue }
                let progress = max(0.01, expansionProgress(for: pageEntry.entry.id))
                let contentX = self.contentX + accordionContentIndent
                let contentWidth = max(1, self.contentWidth - accordionContentIndent)
                let pageRect = CGRect(
                    x: contentX,
                    y: y + pageEntry.topSpacing * progress,
                    width: contentWidth,
                    height: page.measuredSize.height
                )
                let clipRect = CGRect(
                    x: contentX,
                    y: y,
                    width: contentWidth,
                    height: allocatedHeight
                )

                context.saveGState()
                context.clip(to: clipRect)
                context.setAlpha(min(1, progress * 1.35))
                drawSelectionIfNeeded(
                    pageEntry: pageEntry,
                    pageEntryIndex: index,
                    page: page,
                    pageRect: pageRect,
                    theme: theme,
                    context: context
                )
                renderer.draw(
                    block: pageEntry.entry.block,
                    page: page,
                    in: context,
                    rect: pageRect,
                    theme: theme,
                    coordinates: .yDown
                )
                context.restoreGState()
            case .fileChangeCard:
                let allocatedHeight = heightIndex.height(at: index) ?? 0
                guard allocatedHeight > 0.5 else { continue }
                let progress = max(0.01, expansionProgress(for: pageEntry.entry.id))
                let rect = contentRect(y: y, height: fileChangeCardHeight(for: pageEntry.entry))
                let clipRect = contentRect(y: y, height: allocatedHeight)
                context.saveGState()
                context.clip(to: clipRect)
                context.setAlpha(min(1, progress * 1.35))
                drawFileChangeCard(entry: pageEntry.entry, in: rect, context: context)
                context.restoreGState()
            case .compaction:
                drawCompaction(entry: pageEntry.entry, at: y, context: context)
            case .thinkingIndicator:
                drawThinkingIndicator(entry: pageEntry.entry, at: y, context: context)
            case .bottomSpacer:
                continue
            }
        }
        drawVisibleMessageHoverChrome(in: context, range: range)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = heightIndex.index(containingOffset: point.y),
              pageEntries.indices.contains(index) else {
            clearTextSelection()
            super.mouseDown(with: event)
            return
        }

        let pageEntry = pageEntries[index]
        if let hit = messageHoverHit(at: point), isCopyButtonHit(hit) {
            pressedCopyKey = hit.key
            hoveredMessageKey = hit.key
            hoveredCopyKey = hit.key
            needsDisplay = true
            return
        }

        if pageEntry.chrome == .accordionHeader || pageEntry.chrome == .previousMessagesHeader {
            let y = heightIndex.prefixSum(upTo: index)
            if accordionHeaderRect(for: pageEntry.entry, at: y).contains(point) {
                toggleAccordion(id: pageEntry.entry.id)
                return
            }
        }

        if let endpoint = textEndpoint(at: point, allowNearest: false) {
            window?.makeFirstResponder(self)
            textSelection = TextSelection(anchor: endpoint, focus: endpoint)
            isSelectingText = true
            needsDisplay = true
            return
        }

        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isSelectingText else {
            super.mouseMoved(with: event)
            return
        }
        updateMessageHover(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        let currentPoint = currentWindowMousePoint()
        let currentHit = currentPoint.flatMap { messageHoverHit(at: $0) }
        if let currentPoint,
           currentHit != nil {
            updateMessageHover(at: currentPoint)
            super.mouseExited(with: event)
            return
        }
        clearMessageHover()
        super.mouseExited(with: event)
    }

    private func currentWindowMousePoint() -> CGPoint? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return nil }
        return point
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedCopyKey != nil {
            updateCopyButtonPress(at: convert(event.locationInWindow, from: nil))
            return
        }

        guard isSelectingText, let selection = textSelection else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let endpoint = textEndpoint(at: point, allowNearest: true),
           endpoint != selection.focus {
            textSelection = TextSelection(anchor: selection.anchor, focus: endpoint)
            needsDisplay = true
        }
        _ = autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let pressedCopyKey {
            let point = convert(event.locationInWindow, from: nil)
            let hit = messageHoverHit(at: point)
            if hit?.key == pressedCopyKey,
               let hit,
               isCopyButtonHit(hit) {
                copyMessage(hit)
            }
            self.pressedCopyKey = nil
            updateMessageHover(at: point)
            needsDisplay = true
            return
        }

        if isSelectingText {
            isSelectingText = false
            if textSelection?.isEmpty == true {
                textSelection = nil
                needsDisplay = true
            }
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedTranscriptText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let first = firstTextEndpoint(), let last = lastTextEndpoint(), first != last else { return }
        window?.makeFirstResponder(self)
        textSelection = TextSelection(anchor: first, focus: last)
        needsDisplay = true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return selectedTranscriptText?.isEmpty == false
        }
        if item.action == #selector(selectAll(_:)) {
            return firstTextEndpoint() != nil
        }
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let theme = currentTheme
        let visibleRange = heightIndex.indexRange(
            intersectingOffset: visibleRect.minY,
            length: visibleRect.height,
            overscan: 80
        )
        for index in visibleRange {
            guard pageEntries.indices.contains(index) else {
                continue
            }
            let y = heightIndex.prefixSum(upTo: index)
            let pageEntry = pageEntries[index]
            switch pageEntry.chrome {
            case .accordionHeader, .previousMessagesHeader:
                addCursorRect(accordionHeaderRect(for: pageEntry.entry, at: y), cursor: .pointingHand)
            case .plain, .accordionContent:
                if let rect = selectablePageRect(
                    for: pageEntry,
                    at: index,
                    y: y,
                    theme: theme
                ) {
                    addCursorRect(rect, cursor: .iBeam)
                }
                if let accessoryRect = messageAccessoryCursorRect(
                    for: pageEntry,
                    at: index
                ) {
                    addCursorRect(accessoryRect, cursor: .arrow)
                }
            case .fileChangeCard, .compaction, .thinkingIndicator, .bottomSpacer:
                continue
            }
        }
    }

    private var contentWidth: CGFloat {
        min(maxContentWidth, max(1, documentWidth - horizontalInset * 2))
    }

    private var contentX: CGFloat {
        max(horizontalInset, floor((documentWidth - contentWidth) / 2))
    }

    private var currentTheme: CodexTrajectoryTheme {
        Self.theme(for: effectiveAppearance, transcriptFontSize: transcriptFontSize)
    }

    private func contentRect(y: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: contentX, y: y, width: contentWidth, height: height)
    }

    private func updateStreamingFadeState(for entries: [CodexTrajectoryTranscriptDisplayEntry]) {
        let streamingIDs = Set(entries.flatMap(\.streamingAssistantBlockIDs))
        let now = ProcessInfo.processInfo.systemUptime
        streamingFadeState.updateActiveStreamingIDs(streamingIDs, now: now)
        if streamingFadeState.hasActiveFades {
            scheduleStreamingFadeInvalidation()
        }
    }

    private func scheduleStreamingFadeInvalidation() {
        guard streamingFadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            self.streamingFadeState.pruneExpired(now: now, duration: self.streamingFadeDuration)
            self.needsDisplay = true
            if !self.streamingFadeState.hasActiveFades {
                timer.invalidate()
                self.streamingFadeTimer = nil
            }
        }
        streamingFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateThinkingAnimationState(for entries: [CodexTrajectoryTranscriptDisplayEntry]) {
        let hasAnimatedThinkingIndicator = entries.contains { $0.isThinkingIndicator }
        if hasAnimatedThinkingIndicator {
            scheduleThinkingAnimationInvalidation()
        } else {
            thinkingAnimationTimer?.invalidate()
            thinkingAnimationTimer = nil
            thinkingAnimationStartTime = ProcessInfo.processInfo.systemUptime
        }
    }

    private func scheduleThinkingAnimationInvalidation() {
        guard thinkingAnimationTimer == nil else { return }
        thinkingAnimationStartTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            invalidateVisibleThinkingIndicators()
        }
        thinkingAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func invalidateVisibleThinkingIndicators() {
        let visible = visibleRect
        let range = heightIndex.indexRange(
            intersectingOffset: visible.minY,
            length: visible.height,
            overscan: 80
        )
        for index in range {
            guard pageEntries.indices.contains(index),
                  pageEntries[index].chrome == .thinkingIndicator else {
                continue
            }
            let y = heightIndex.prefixSum(upTo: index)
            setNeedsDisplay(contentRect(y: y, height: thinkingIndicatorHeight).insetBy(dx: -4, dy: -4))
        }
    }

    private func streamingAlpha(for entry: CodexTrajectoryTranscriptDisplayEntry) -> CGFloat {
        guard entry.block.kind == .assistantText,
              entry.block.isStreaming else {
            return 1
        }
        return streamingFadeState.alpha(
            for: entry.block.id,
            now: ProcessInfo.processInfo.systemUptime,
            duration: streamingFadeDuration
        )
    }

    private func clearTextSelection() {
        guard textSelection != nil else { return }
        textSelection = nil
        isSelectingText = false
        needsDisplay = true
    }

    private func updateMessageHover(at point: CGPoint) {
        let hit = messageHoverHit(at: point)
        let nextMessageKey = hit?.key
        let nextCopyKey = hit.map { isCopyButtonHit($0) } == true ? hit?.key : nil
        guard nextMessageKey != hoveredMessageKey || nextCopyKey != hoveredCopyKey else {
            return
        }
        hoveredMessageKey = nextMessageKey
        hoveredCopyKey = nextCopyKey
        if let nextMessageKey {
            startMessageHoverFade(for: nextMessageKey)
        }
        needsDisplay = true
    }

    private func updateCopyButtonPress(at point: CGPoint) {
        guard let pressedCopyKey else { return }
        let hit = messageHoverHit(at: point)
        let nextCopyKey = hit?.key == pressedCopyKey && hit.map { isCopyButtonHit($0) } == true
            ? pressedCopyKey
            : nil
        let nextMessageKey = hit?.key == pressedCopyKey ? pressedCopyKey : hoveredMessageKey
        guard nextMessageKey != hoveredMessageKey || nextCopyKey != hoveredCopyKey else {
            return
        }
        hoveredMessageKey = nextMessageKey
        hoveredCopyKey = nextCopyKey
        if let nextMessageKey {
            startMessageHoverFade(for: nextMessageKey)
        }
        needsDisplay = true
    }

    private func clearMessageHover() {
        guard hoveredMessageKey != nil || hoveredCopyKey != nil else { return }
        hoveredMessageKey = nil
        hoveredCopyKey = nil
        pruneMessageHoverFades()
        needsDisplay = true
    }

    private func startMessageHoverFade(for key: MessageHoverKey) {
        guard messageHoverFadeStartTimes[key] == nil else { return }
        messageHoverFadeStartTimes[key] = ProcessInfo.processInfo.systemUptime
        scheduleMessageHoverFadeInvalidation()
    }

    private func messageHoverFadeAlpha(for key: MessageHoverKey) -> CGFloat {
        guard let startTime = messageHoverFadeStartTimes[key] else { return 1 }
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let rawProgress = min(1, max(0, elapsed / messageHoverFadeDuration))
        return CGFloat(rawProgress * rawProgress * (3 - 2 * rawProgress))
    }

    private func scheduleMessageHoverFadeInvalidation() {
        guard messageHoverFadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            pruneMessageHoverFades()
            needsDisplay = true
            if messageHoverFadeStartTimes.isEmpty {
                timer.invalidate()
                messageHoverFadeTimer = nil
            }
        }
        messageHoverFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pruneMessageHoverFades() {
        let now = ProcessInfo.processInfo.systemUptime
        messageHoverFadeStartTimes = messageHoverFadeStartTimes.filter { key, startTime in
            (hoveredMessageKey == key || copiedMessageKey == key)
                && now - startTime < messageHoverFadeDuration
        }
    }

    private func copyMessage(_ hit: MessageHoverHit) {
        let text = hit.entry.block.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopiedMessageIcon(for: hit.key)
    }

    private func showCopiedMessageIcon(for key: MessageHoverKey) {
        copiedIconResetTimer?.invalidate()
        copiedMessageKey = key
        needsDisplay = true

        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            if copiedMessageKey == key {
                copiedMessageKey = nil
                needsDisplay = true
            }
            copiedIconResetTimer = nil
        }
        copiedIconResetTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func clampSelectionToCurrentText() {
        guard let selection = textSelection else { return }
        guard let anchor = clampedEndpoint(selection.anchor),
              let focus = clampedEndpoint(selection.focus) else {
            textSelection = nil
            isSelectingText = false
            return
        }
        textSelection = TextSelection(anchor: anchor, focus: focus)
    }

    private func clampedEndpoint(_ endpoint: TextSelectionEndpoint) -> TextSelectionEndpoint? {
        guard let pageEntry = pageEntries.first(where: { pageEntry in
            pageEntry.page != nil && pageEntry.entry.block.id == endpoint.blockID
        }) else {
            return nil
        }
        let theme = currentTheme
        let length = codexTrajectoryRenderedText(for: pageEntry.entry.block, theme: theme).plainText.utf16.count
        return TextSelectionEndpoint(
            blockID: endpoint.blockID,
            utf16Offset: min(max(endpoint.utf16Offset, 0), length)
        )
    }

    private func normalizedSelection(_ selection: TextSelection) -> NormalizedTextSelection? {
        guard let anchorBounds = pageEntryBounds(forBlockID: selection.anchor.blockID),
              let focusBounds = pageEntryBounds(forBlockID: selection.focus.blockID) else {
            return nil
        }

        let anchorIsLower: Bool
        if selection.anchor.blockID == selection.focus.blockID {
            anchorIsLower = selection.anchor.utf16Offset <= selection.focus.utf16Offset
        } else {
            anchorIsLower = anchorBounds.first <= focusBounds.first
        }

        if anchorIsLower {
            return NormalizedTextSelection(
                lower: selection.anchor,
                upper: selection.focus,
                lowerBlockIndex: anchorBounds.first,
                upperBlockIndex: focusBounds.last
            )
        }
        return NormalizedTextSelection(
            lower: selection.focus,
            upper: selection.anchor,
            lowerBlockIndex: focusBounds.first,
            upperBlockIndex: anchorBounds.last
        )
    }

    private func pageEntryBounds(forBlockID blockID: String) -> (first: Int, last: Int)? {
        var first: Int?
        var last: Int?
        for (index, pageEntry) in pageEntries.enumerated() {
            guard pageEntry.page != nil, pageEntry.entry.block.id == blockID else { continue }
            if first == nil {
                first = index
            }
            last = index
        }
        guard let first, let last else { return nil }
        return (first, last)
    }

    private func rebuildLayout() {
#if DEBUG
        let start = CodexAppServerTiming.now()
        debugLayoutRequestCount = 0
        debugLayoutCacheHitCount = 0
#endif
        let theme = currentTheme
        let layoutWidth = contentWidth
        pageEntries.removeAll(keepingCapacity: true)
        messageChromeSnapshotsByPageEntryIndex.removeAll(keepingCapacity: true)
        activeLayoutCacheKeys.removeAll(keepingCapacity: true)
        var heights: [CGFloat] = []

        func appendEntry(_ entry: CodexTrajectoryTranscriptDisplayEntry) {
            if entry.isThinkingIndicator {
                let fullHeight = thinkingIndicatorHeight + rowSpacing
                pageEntries.append(
                    PageEntry(
                        entry: entry,
                        page: nil,
                        chrome: .thinkingIndicator,
                        topSpacing: 0,
                        bottomSpacing: rowSpacing,
                        fullContentHeight: fullHeight
                    )
                )
                heights.append(fullHeight)
            } else if entry.isCompaction {
                pageEntries.append(
                    PageEntry(
                        entry: entry,
                        page: nil,
                        chrome: .compaction,
                        topSpacing: 0,
                        bottomSpacing: rowSpacing,
                        fullContentHeight: compactionHeight
                    )
                )
                heights.append(compactionHeight)
            } else if entry.isPreviousMessages {
                let progress = expansionProgress(for: entry.id)
                let headerHeight = accordionHeaderHeight(for: entry)
                pageEntries.append(
                    PageEntry(
                        entry: entry,
                        page: nil,
                        chrome: .previousMessagesHeader,
                        topSpacing: 0,
                        bottomSpacing: progress > 0 ? 0 : rowSpacing,
                        fullContentHeight: headerHeight
                    )
                )
                heights.append(headerHeight + (progress > 0 ? 0 : rowSpacing))

                if progress > 0 {
                    for previousEntry in entry.previousEntries {
                        appendEntry(previousEntry)
                    }
                }
            } else if entry.isAccordion {
                let progress = expansionProgress(for: entry.id)
                let headerHeight = accordionHeaderHeight(for: entry)
                let collapsedSpacing = entry.kind == .toolRun ? CGFloat(4) : rowSpacing
                pageEntries.append(
                    PageEntry(
                        entry: entry,
                        page: nil,
                        chrome: .accordionHeader,
                        topSpacing: 0,
                        bottomSpacing: progress > 0 ? 0 : collapsedSpacing,
                        fullContentHeight: headerHeight
                    )
                )
                heights.append(headerHeight + (progress > 0 ? 0 : collapsedSpacing))

                if progress > 0 {
                    if entry.kind == .toolGroup {
                        for childEntry in entry.childToolRunEntries {
                            appendEntry(childEntry)
                        }
                    } else if !entry.fileChanges.isEmpty {
                        let fullHeight = fileChangeCardHeight(for: entry) + rowSpacing
                        pageEntries.append(
                            PageEntry(
                                entry: entry,
                                page: nil,
                                chrome: .fileChangeCard,
                                topSpacing: 0,
                                bottomSpacing: rowSpacing,
                                fullContentHeight: fullHeight
                            )
                        )
                        heights.append(max(0, fullHeight * progress))
                    } else {
                        let contentWidth = max(1, layoutWidth - accordionContentIndent)
                        let layout = layout(for: entry.block, width: contentWidth, theme: theme)
                        for page in layout.pages {
                            let isFirstPage = page.pageIndex == 0
                            let isLastPage = page.pageIndex == layout.pages.count - 1
                            let topSpacing = isFirstPage ? accordionContentTopSpacing : 0
                            let bottomSpacing = isLastPage ? rowSpacing : 0
                            let fullHeight = topSpacing + page.measuredSize.height + bottomSpacing
                            pageEntries.append(
                                PageEntry(
                                    entry: entry,
                                    page: page,
                                    chrome: .accordionContent,
                                    topSpacing: topSpacing,
                                    bottomSpacing: bottomSpacing,
                                    fullContentHeight: fullHeight
                                )
                            )
                            heights.append(max(0, fullHeight * progress))
                        }
                    }
                }
            } else {
                let entryLayoutWidth = plainLayoutWidth(for: entry, theme: theme)
                let layout = layout(for: entry.block, width: entryLayoutWidth, theme: theme)
                let verticalSpacing = plainVerticalSpacing(for: entry)
                for page in layout.pages {
                    let fullHeight = verticalSpacing.top + page.measuredSize.height + verticalSpacing.bottom
                    pageEntries.append(
                        PageEntry(
                            entry: entry,
                            page: page,
                            chrome: .plain,
                            topSpacing: verticalSpacing.top,
                            bottomSpacing: verticalSpacing.bottom,
                            fullContentHeight: fullHeight
                        )
                    )
                    heights.append(fullHeight)
                }
            }
        }

        if !entries.isEmpty {
            appendTranscriptTopSpacer(to: &heights)
        }
        for entry in entries {
            appendEntry(entry)
        }
        if !entries.isEmpty {
            appendBottomSpacer(to: &heights)
        }

        pruneLayoutCache()

        heightIndex.replaceAll(with: heights)
        rebuildMessageChromeSnapshots()
        setFrameSize(NSSize(width: documentWidth, height: max(1, heightIndex.totalHeight)))
        clampSelectionToCurrentText()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
#if DEBUG
        if entries.count >= 100 {
            CodexAppServerTiming.log("transcript.rebuildLayout", [
                "entries": entries.count,
                "pages": pageEntries.count,
                "height": Int(heightIndex.totalHeight),
                "layout_requests": debugLayoutRequestCount,
                "cache_hits": debugLayoutCacheHitCount,
                "ms": CodexAppServerTiming.ms(CodexAppServerTiming.elapsedMs(since: start)),
            ])
        } else {
            CodexAppServerTiming.logSlow("transcript.rebuildLayout", start: start, thresholdMs: 8, [
                "entries": entries.count,
                "pages": pageEntries.count,
                "height": Int(heightIndex.totalHeight),
                "layout_requests": debugLayoutRequestCount,
                "cache_hits": debugLayoutCacheHitCount,
            ])
        }
#endif
    }

    private func appendTranscriptTopSpacer(to heights: inout [CGFloat]) {
        let entry = CodexTrajectoryTranscriptDisplayEntry(
            id: "top-spacer",
            kind: .plain,
            title: "",
            subtitle: "",
            statusText: nil,
            block: CodexTrajectoryBlock(
                id: "top-spacer",
                kind: .status,
                title: "",
                text: "",
                isStreaming: false,
                createdAt: .distantPast
            )
        )
        pageEntries.append(
            PageEntry(
                entry: entry,
                page: nil,
                chrome: .bottomSpacer,
                topSpacing: 0,
                bottomSpacing: 0,
                fullContentHeight: transcriptTopSpacerHeight
            )
        )
        heights.append(transcriptTopSpacerHeight)
    }

    private func appendBottomSpacer(to heights: inout [CGFloat]) {
        let entry = CodexTrajectoryTranscriptDisplayEntry(
            id: "bottom-spacer",
            kind: .plain,
            title: "",
            subtitle: "",
            statusText: nil,
            block: CodexTrajectoryBlock(
                id: "bottom-spacer",
                kind: .status,
                title: "",
                text: "",
                isStreaming: false,
                createdAt: .distantPast
            )
        )
        pageEntries.append(
            PageEntry(
                entry: entry,
                page: nil,
                chrome: .bottomSpacer,
                topSpacing: 0,
                bottomSpacing: 0,
                fullContentHeight: bottomSpacerHeight
            )
        )
        heights.append(bottomSpacerHeight)
    }

    private func fileChangeCardHeight(for entry: CodexTrajectoryTranscriptDisplayEntry) -> CGFloat {
        guard !entry.fileChanges.isEmpty else { return 0 }
        return fileChangeHeaderHeight + CGFloat(entry.fileChanges.count) * fileChangeRowHeight
    }

    private func layout(
        for block: CodexTrajectoryBlock,
        width: CGFloat,
        theme: CodexTrajectoryTheme
    ) -> CodexTrajectoryBlockLayout {
#if DEBUG
        debugLayoutRequestCount += 1
#endif
        let cacheKey = LayoutCacheKey(
            block: block,
            width: Int(width.rounded()),
            themeIdentifier: theme.identifier
        )
        activeLayoutCacheKeys.insert(cacheKey)
        if let cached = cachedLayouts[cacheKey] {
#if DEBUG
            debugLayoutCacheHitCount += 1
#endif
            return cached.layout
        }

        let layout = layoutEngine.layout(
            block: block,
            configuration: CodexTrajectoryLayoutConfiguration(width: width),
            theme: theme
        )
        cachedLayouts[cacheKey] = CachedLayout(block: block, layout: layout)
        return layout
    }

    private func plainLayoutWidth(
        for entry: CodexTrajectoryTranscriptDisplayEntry,
        theme: CodexTrajectoryTheme
    ) -> CGFloat {
        guard entry.isUserMessage else { return contentWidth }
        let maxWidth = min(maxUserBubbleWidth, contentWidth * 0.86)
        guard maxWidth > 1 else { return 1 }
        let minWidth = min(maxWidth, 44)
        let rendered = codexTrajectoryRenderedText(for: entry.block, theme: theme)
        let style = theme.style(for: .userText)
        let insets = theme.contentInsets(for: .userText)
        let maxLineWidth = rendered.plainText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(CGFloat(0)) { current, line in
                max(current, measureTextWidth(String(line), font: style.font))
            }
        let idealWidth = ceil(maxLineWidth + insets.left + insets.right + 2)
        return min(maxWidth, max(minWidth, idealWidth))
    }

    private func plainVerticalSpacing(
        for entry: CodexTrajectoryTranscriptDisplayEntry
    ) -> (top: CGFloat, bottom: CGFloat) {
        if entry.isChatMessage {
            return (plainChatTopSpacing, plainChatBottomSpacing)
        }
        return (rowSpacing / 2, rowSpacing / 2)
    }

    private func plainPageRect(
        for pageEntry: PageEntry,
        page: CodexTrajectoryLayoutPage,
        at y: CGFloat
    ) -> CGRect {
        let width = min(contentWidth, page.measuredSize.width)
        let x = pageEntry.entry.isUserMessage
            ? contentX + contentWidth - width
            : contentX
        return CGRect(
            x: x,
            y: y + pageEntry.topSpacing,
            width: width,
            height: page.measuredSize.height
        )
    }

    private func selectablePageRect(
        for pageEntry: PageEntry,
        at index: Int,
        y: CGFloat,
        theme: CodexTrajectoryTheme
    ) -> CGRect? {
        guard let page = pageEntry.page else { return nil }
        switch pageEntry.chrome {
        case .plain:
            return plainPageRect(for: pageEntry, page: page, at: y)
        case .accordionContent:
            let allocatedHeight = heightIndex.height(at: index) ?? 0
            guard allocatedHeight > 0.5 else { return nil }
            let progress = max(0.01, expansionProgress(for: pageEntry.entry.id))
            return CGRect(
                x: contentX + accordionContentIndent,
                y: y + pageEntry.topSpacing * progress,
                width: max(1, contentWidth - accordionContentIndent),
                height: page.measuredSize.height
            )
        case .accordionHeader, .fileChangeCard, .compaction, .previousMessagesHeader, .thinkingIndicator, .bottomSpacer:
            return nil
        }
    }

    private func messageAccessoryCursorRect(
        for pageEntry: PageEntry,
        at index: Int
    ) -> CGRect? {
        guard pageEntry.chrome == .plain,
              pageEntry.entry.isChatMessage,
              let snapshot = messageChromeSnapshotsByPageEntryIndex[index] else {
            return nil
        }
        return snapshot.accessoryRowRect
    }

    private func messageHoverHit(at point: CGPoint) -> MessageHoverHit? {
        guard !pageEntries.isEmpty,
              let index = heightIndex.index(containingOffset: point.y),
              let snapshot = messageChromeSnapshotsByPageEntryIndex[index],
              let zone = snapshot.zone(at: point) else {
            return nil
        }
        return MessageHoverHit(snapshot: snapshot, zone: zone)
    }

    private func rebuildMessageChromeSnapshots() {
        messageChromeSnapshotsByPageEntryIndex.removeAll(keepingCapacity: true)
        guard !pageEntries.isEmpty else { return }
        for (index, pageEntry) in pageEntries.enumerated() {
            guard pageEntry.chrome == .plain,
                  pageEntry.entry.isChatMessage,
                  let page = pageEntry.page else {
                continue
            }
            let y = heightIndex.prefixSum(upTo: index)
            let pageRect = plainPageRect(for: pageEntry, page: page, at: y)
            let snapshot = makeMessageChromeSnapshot(
                for: pageEntry.entry,
                pageIndex: page.pageIndex,
                pageRect: pageRect
            )
            messageChromeSnapshotsByPageEntryIndex[index] = snapshot
        }
    }

    private func makeMessageChromeSnapshot(
        for entry: CodexTrajectoryTranscriptDisplayEntry,
        pageIndex: Int,
        pageRect: CGRect
    ) -> MessageChromeSnapshot {
        let font = hoverTimestampFont
        let timestamp = timestampText(for: entry)
        let timestampWidth = timestamp.isEmpty ? 0 : ceil(measureTextWidth(timestamp, font: font))
        let buttonWidth = CodexTranscriptCopyIconButton.size.width
        let width = timestampWidth + (timestamp.isEmpty ? 0 : 8) + buttonWidth
        let x = entry.isUserMessage ? pageRect.maxX - width : pageRect.minX
        let metadataRect = CGRect(
            x: x,
            y: pageRect.maxY + messageAccessoryTopGap,
            width: max(buttonWidth, width),
            height: messageAccessoryHeight
        )
        let accessoryRowMinX = min(pageRect.minX, metadataRect.minX)
        let accessoryRowMaxX = max(pageRect.maxX, metadataRect.maxX)
        let accessoryRowRect = CGRect(
            x: accessoryRowMinX,
            y: pageRect.maxY,
            width: max(1, accessoryRowMaxX - accessoryRowMinX),
            height: messageAccessoryTopGap + messageAccessoryHeight
        )
        let copyRect: CGRect
        if entry.isUserMessage {
            copyRect = CGRect(
                x: metadataRect.maxX - CodexTranscriptCopyIconButton.size.width,
                y: metadataRect.minY,
                width: CodexTranscriptCopyIconButton.size.width,
                height: CodexTranscriptCopyIconButton.size.height
            )
        } else {
            copyRect = CGRect(
                x: metadataRect.minX,
                y: metadataRect.minY,
                width: CodexTranscriptCopyIconButton.size.width,
                height: CodexTranscriptCopyIconButton.size.height
            )
        }
        let timestampRect: CGRect?
        if timestamp.isEmpty {
            timestampRect = nil
        } else {
            timestampRect = CGRect(
                x: entry.isUserMessage ? metadataRect.minX : copyRect.maxX + 8,
                y: metadataRect.minY + (metadataRect.height - 15) / 2,
                width: max(1, metadataRect.width - copyRect.width - 8),
                height: 15
            )
        }
        let copyHitRect = copyRect.insetBy(dx: -4, dy: -4)
        let interactionRect = accessoryRowRect
            .union(copyHitRect)
            .insetBy(
                dx: -messageAccessoryHorizontalRetention,
                dy: -messageAccessoryVerticalRetention
            )
        return MessageChromeSnapshot(
            key: MessageHoverKey(blockID: entry.block.id, pageIndex: pageIndex),
            entry: entry,
            pageRect: pageRect,
            accessoryRowRect: interactionRect,
            metadataRect: metadataRect,
            timestampRect: timestampRect,
            timestampText: timestamp,
            copyRect: copyRect,
            copyHitRect: copyHitRect
        )
    }

    private func isCopyButtonHit(_ hit: MessageHoverHit) -> Bool {
        hit.zone == .copy
    }

    private var hoverTimestampFont: CTFont {
        CTFontCreateUIFontForLanguage(.system, 11, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    }

    private func timestampText(for entry: CodexTrajectoryTranscriptDisplayEntry) -> String {
        guard entry.block.createdAt > .distantPast.addingTimeInterval(1) else { return "" }
        return timestampFormatter.string(from: entry.block.createdAt)
    }

    private func textEndpoint(at point: CGPoint, allowNearest: Bool) -> TextSelectionEndpoint? {
        let theme = currentTheme
        let lookupRange = heightIndex.indexRange(
            intersectingOffset: visibleRect.minY,
            length: visibleRect.height,
            overscan: allowNearest ? 2_000 : 80
        )
        var nearest: (distance: CGFloat, endpoint: TextSelectionEndpoint)?

        for index in lookupRange {
            guard pageEntries.indices.contains(index) else { continue }
            let pageEntry = pageEntries[index]
            guard let page = pageEntry.page else { continue }
            let y = heightIndex.prefixSum(upTo: index)
            guard let pageRect = selectablePageRect(for: pageEntry, at: index, y: y, theme: theme) else {
                continue
            }

            if pageRect.contains(point),
               let endpoint = textEndpoint(
                   in: pageEntry,
                   pageEntryIndex: index,
                   page: page,
                   pageRect: pageRect,
                   point: point,
                   theme: theme
               ) {
                return endpoint
            }

            guard allowNearest else { continue }
            let dy: CGFloat
            if point.y < pageRect.minY {
                dy = pageRect.minY - point.y
            } else if point.y > pageRect.maxY {
                dy = point.y - pageRect.maxY
            } else {
                dy = 0
            }
            let clampedPoint = CGPoint(
                x: min(max(point.x, pageRect.minX), pageRect.maxX),
                y: min(max(point.y, pageRect.minY), pageRect.maxY)
            )
            if let endpoint = textEndpoint(
                in: pageEntry,
                pageEntryIndex: index,
                page: page,
                pageRect: pageRect,
                point: clampedPoint,
                theme: theme
            ),
                nearest == nil || dy < nearest!.distance {
                nearest = (dy, endpoint)
            }
        }

        return nearest?.endpoint
    }

    private func textEndpoint(
        in pageEntry: PageEntry,
        pageEntryIndex: Int,
        page: CodexTrajectoryLayoutPage,
        pageRect: CGRect,
        point: CGPoint,
        theme: CodexTrajectoryTheme
    ) -> TextSelectionEndpoint? {
        let pageInfo = Self.pageTextInfo(for: pageEntry.entry.block, page: page, theme: theme)
        let pageText = pageInfo.text
        let textLength = (pageText as NSString).length
        guard textLength > 0 else {
            return TextSelectionEndpoint(
                blockID: pageEntry.entry.block.id,
                utf16Offset: pageInfo.globalUTF16Range.lowerBound
            )
        }

        let frame = textFrame(
            attributed: pageInfo.attributedString,
            pageRect: pageRect,
            blockKind: pageEntry.entry.block.kind,
            theme: theme
        )
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else {
            return TextSelectionEndpoint(
                blockID: pageEntry.entry.block.id,
                utf16Offset: pageInfo.globalUTF16Range.lowerBound
            )
        }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        let localPoint = CGPoint(x: point.x - pageRect.minX, y: pageRect.maxY - point.y)
        var bestLineIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (lineIndex, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let origin = origins[lineIndex]
            let minY = origin.y - descent - leading / 2
            let maxY = origin.y + ascent + leading / 2
            if localPoint.y >= minY, localPoint.y <= maxY {
                bestLineIndex = lineIndex
                break
            }
            let distance = localPoint.y < minY ? minY - localPoint.y : localPoint.y - maxY
            if distance < bestDistance {
                bestDistance = distance
                bestLineIndex = lineIndex
            }
        }

        let line = lines[bestLineIndex]
        let origin = origins[bestLineIndex]
        let range = CTLineGetStringRange(line)
        let lower = max(0, range.location)
        let upper = min(textLength, lower + max(0, range.length))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let linePoint = CGPoint(
            x: min(max(localPoint.x - origin.x, 0), max(0, width)),
            y: localPoint.y - origin.y
        )
        var offset = CTLineGetStringIndexForPosition(line, linePoint)
        if offset == kCFNotFound {
            offset = linePoint.x <= 0 ? lower : upper
        }
        offset = min(max(offset, lower), upper)
        return TextSelectionEndpoint(
            blockID: pageEntry.entry.block.id,
            utf16Offset: pageInfo.globalUTF16Range.lowerBound + offset
        )
    }

    private func drawSelectionIfNeeded(
        pageEntry: PageEntry,
        pageEntryIndex: Int,
        page: CodexTrajectoryLayoutPage,
        pageRect: CGRect,
        theme: CodexTrajectoryTheme,
        context: CGContext
    ) {
        guard let selection = textSelection, !selection.isEmpty else { return }
        let pageInfo = Self.pageTextInfo(for: pageEntry.entry.block, page: page, theme: theme)
        let pageText = pageInfo.text
        guard let range = selectedUTF16Range(
            forPageEntryIndex: pageEntryIndex,
            pageEntry: pageEntry,
            page: page,
            pageText: pageText,
            selection: selection
        ) else {
            return
        }

        let frame = textFrame(
            attributed: pageInfo.attributedString,
            pageRect: pageRect,
            blockKind: pageEntry.entry.block.kind,
            theme: theme
        )
        let rects = selectionRects(
            in: frame,
            selectedRange: range,
            pageRect: pageRect
        )
        guard !rects.isEmpty else { return }

        let fill = Self.color(.selectedTextBackgroundColor, appearance: effectiveAppearance)
            .withAlphaComponent(0.62)
        context.saveGState()
        context.setFillColor(fill.cgColor)
        for rect in rects {
            context.fill(rect)
        }
        context.restoreGState()
    }

    private func selectedUTF16Range(
        forPageEntryIndex pageEntryIndex: Int,
        pageEntry: PageEntry,
        page: CodexTrajectoryLayoutPage,
        pageText: String,
        selection: TextSelection
    ) -> Range<Int>? {
        guard let normalized = normalizedSelection(selection) else { return nil }
        let theme = currentTheme
        let pageInfo = Self.pageTextInfo(for: pageEntry.entry.block, page: page, theme: theme)
        let pageRange = pageInfo.globalUTF16Range
        let textLength = (pageText as NSString).length
        guard textLength > 0 else { return nil }

        let lowerGlobal: Int
        let upperGlobal: Int
        if normalized.lower.blockID == normalized.upper.blockID {
            guard pageEntry.entry.block.id == normalized.lower.blockID else { return nil }
            lowerGlobal = max(normalized.lower.utf16Offset, pageRange.lowerBound)
            upperGlobal = min(normalized.upper.utf16Offset, pageRange.upperBound)
        } else if pageEntry.entry.block.id == normalized.lower.blockID {
            lowerGlobal = max(normalized.lower.utf16Offset, pageRange.lowerBound)
            upperGlobal = pageRange.upperBound
        } else if pageEntry.entry.block.id == normalized.upper.blockID {
            lowerGlobal = pageRange.lowerBound
            upperGlobal = min(normalized.upper.utf16Offset, pageRange.upperBound)
        } else if pageEntryIndex > normalized.lowerBlockIndex,
                  pageEntryIndex < normalized.upperBlockIndex {
            lowerGlobal = pageRange.lowerBound
            upperGlobal = pageRange.upperBound
        } else {
            return nil
        }

        let lower = min(max(lowerGlobal - pageRange.lowerBound, 0), textLength)
        let upper = min(max(upperGlobal - pageRange.lowerBound, 0), textLength)
        return upper > lower ? lower..<upper : nil
    }

    private func selectionRects(
        in frame: CTFrame,
        selectedRange: Range<Int>,
        pageRect: CGRect
    ) -> [CGRect] {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var rects: [CGRect] = []
        for (lineIndex, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let lineLower = max(0, lineRange.location)
            let lineUpper = lineLower + max(0, lineRange.length)
            let lower = max(selectedRange.lowerBound, lineLower)
            let upper = min(selectedRange.upperBound, lineUpper)
            guard upper > lower else { continue }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let origin = origins[lineIndex]
            let startX = CTLineGetOffsetForStringIndex(line, lower, nil)
            let endX = CTLineGetOffsetForStringIndex(line, upper, nil)
            let width = max(2, abs(endX - startX))
            let yUpTop = origin.y + ascent + leading / 2
            let yUpBottom = origin.y - descent - leading / 2
            rects.append(
                CGRect(
                    x: pageRect.minX + origin.x + min(startX, endX),
                    y: pageRect.maxY - yUpTop,
                    width: width,
                    height: max(1, yUpTop - yUpBottom)
                )
            )
        }
        return rects
    }

    private func textFrame(
        attributed: CFAttributedString,
        pageRect: CGRect,
        blockKind: CodexTrajectoryBlockKind,
        theme: CodexTrajectoryTheme
    ) -> CTFrame {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let insets = theme.contentInsets(for: blockKind)
        let localTextRect = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: max(0, pageRect.width - insets.left - insets.right),
            height: max(0, pageRect.height - insets.top - insets.bottom)
        )
        let path = CGMutablePath()
        path.addRect(localTextRect)
        return CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
    }

    private var selectedTranscriptText: String? {
        guard let selection = textSelection, !selection.isEmpty else { return nil }
        guard let normalized = normalizedSelection(selection) else { return nil }

        let theme = currentTheme
        var chunks: [String] = []
        for index in normalized.lowerBlockIndex...normalized.upperBlockIndex {
            guard pageEntries.indices.contains(index),
                  let page = pageEntries[index].page else {
                continue
            }
            let pageEntry = pageEntries[index]
            switch pageEntry.chrome {
            case .plain, .accordionContent:
                break
            case .accordionHeader, .fileChangeCard, .compaction, .previousMessagesHeader, .thinkingIndicator, .bottomSpacer:
                continue
            }
            let pageText = Self.pageText(for: pageEntry.entry.block, page: page, theme: theme)
            guard let range = selectedUTF16Range(
                forPageEntryIndex: index,
                pageEntry: pageEntry,
                page: page,
                pageText: pageText,
                selection: selection
            ) else {
                continue
            }
            let text = (pageText as NSString).substring(
                with: NSRange(location: range.lowerBound, length: range.count)
            )
            if !text.isEmpty {
                chunks.append(text)
            }
        }
        let text = chunks.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }

    private func firstTextEndpoint() -> TextSelectionEndpoint? {
        let theme = currentTheme
        for pageEntry in pageEntries {
            guard let page = pageEntry.page else { continue }
            switch pageEntry.chrome {
            case .plain, .accordionContent:
                let pageInfo = Self.pageTextInfo(for: pageEntry.entry.block, page: page, theme: theme)
                if (pageInfo.text as NSString).length > 0 {
                    return TextSelectionEndpoint(
                        blockID: pageEntry.entry.block.id,
                        utf16Offset: pageInfo.globalUTF16Range.lowerBound
                    )
                }
            case .accordionHeader, .fileChangeCard, .compaction, .previousMessagesHeader, .thinkingIndicator, .bottomSpacer:
                continue
            }
        }
        return nil
    }

    private func lastTextEndpoint() -> TextSelectionEndpoint? {
        let theme = currentTheme
        for pageEntry in pageEntries.reversed() {
            guard let page = pageEntry.page else { continue }
            switch pageEntry.chrome {
            case .plain, .accordionContent:
                let pageInfo = Self.pageTextInfo(for: pageEntry.entry.block, page: page, theme: theme)
                let length = (pageInfo.text as NSString).length
                if length > 0 {
                    return TextSelectionEndpoint(
                        blockID: pageEntry.entry.block.id,
                        utf16Offset: pageInfo.globalUTF16Range.upperBound
                    )
                }
            case .accordionHeader, .fileChangeCard, .compaction, .previousMessagesHeader, .thinkingIndicator, .bottomSpacer:
                continue
            }
        }
        return nil
    }

    private static func pageText(
        for block: CodexTrajectoryBlock,
        page: CodexTrajectoryLayoutPage,
        theme: CodexTrajectoryTheme
    ) -> String {
        pageTextInfo(for: block, page: page, theme: theme).text
    }

    private static func pageTextInfo(
        for block: CodexTrajectoryBlock,
        page: CodexTrajectoryLayoutPage,
        theme: CodexTrajectoryTheme
    ) -> (text: String, attributedString: CFAttributedString, globalUTF16Range: Range<Int>) {
        let renderedPage = codexTrajectoryRenderedPage(for: block, page: page, theme: theme)
        let lower = max(0, page.textRange.location)
        let upper = max(lower, page.textRange.upperBound)
        return (renderedPage.plainText, renderedPage.attributedString, lower..<upper)
    }

    private func toggleAccordion(id: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let currentProgress = expansionProgress(for: id, now: now)
        let isExpanding = !expandedAccordionIDs.contains(id)

        if isExpanding {
            expandedAccordionIDs.insert(id)
        } else {
            expandedAccordionIDs.remove(id)
        }

        accordionAnimations[id] = AccordionAnimation(
            startTime: now,
            from: currentProgress,
            to: isExpanding ? 1 : 0
        )
        scheduleAccordionAnimation()
        rebuildLayout()
    }

    private func expansionProgress(
        for id: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> CGFloat {
        guard let animation = accordionAnimations[id] else {
            return expandedAccordionIDs.contains(id) ? 1 : 0
        }
        let rawProgress = min(1, max(0, (now - animation.startTime) / accordionAnimationDuration))
        let easedProgress = rawProgress * rawProgress * (3 - 2 * rawProgress)
        return animation.from + (animation.to - animation.from) * CGFloat(easedProgress)
    }

    private func scheduleAccordionAnimation() {
        guard accordionAnimationTimer == nil else { return }

        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            let completedIDs = accordionAnimations.compactMap { id, animation -> String? in
                now - animation.startTime >= self.accordionAnimationDuration ? id : nil
            }
            for id in completedIDs {
                accordionAnimations.removeValue(forKey: id)
            }

            rebuildLayout()

            if accordionAnimations.isEmpty {
                timer.invalidate()
                accordionAnimationTimer = nil
            }
        }
        accordionAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func accordionHeaderHeight(for entry: CodexTrajectoryTranscriptDisplayEntry) -> CGFloat {
        if entry.isPreviousMessages {
            return previousMessagesHeaderHeight
        }

        let summaryCount = min(entry.toolSummaryLines.count, accordionSummaryLimit)
        return accordionHeaderTitleHeight + CGFloat(summaryCount) * accordionSummaryRowHeight
    }

    private func accordionHeaderRect(for entry: CodexTrajectoryTranscriptDisplayEntry, at y: CGFloat) -> CGRect {
        let topOffset = entry.kind == .toolRun ? CGFloat(2) : rowSpacing / 2
        return contentRect(y: y + topOffset, height: accordionHeaderHeight(for: entry))
    }

    private func drawCompaction(
        entry: CodexTrajectoryTranscriptDisplayEntry,
        at y: CGFloat,
        context: CGContext
    ) {
        let rect = CGRect(
            x: contentX,
            y: y,
            width: contentWidth,
            height: compactionHeight
        )
        let font = CTFontCreateUIFontForLanguage(.system, 11.5, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 11.5, nil)
        let palette = CodexAppServerAdaptivePalette(appearance: effectiveAppearance)
        let textColor = palette.secondaryText
        let lineColor = palette.stroke
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: textColor.cgColor,
        ]
        let attributed = CFAttributedStringCreate(kCFAllocatorDefault, entry.title as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let textWidth = min(
            rect.width * 0.72,
            max(1, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        )
        let gap: CGFloat = 14
        let centerY = rect.midY
        let textRect = CGRect(
            x: rect.midX - textWidth / 2,
            y: centerY - 8,
            width: textWidth,
            height: 16
        )

        context.saveGState()
        context.setStrokeColor(lineColor.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: rect.minX, y: centerY))
        context.addLine(to: CGPoint(x: max(rect.minX, textRect.minX - gap), y: centerY))
        context.move(to: CGPoint(x: min(rect.maxX, textRect.maxX + gap), y: centerY))
        context.addLine(to: CGPoint(x: rect.maxX, y: centerY))
        context.strokePath()
        context.restoreGState()

        drawTruncatedLine(
            entry.title,
            font: font,
            color: textColor.cgColor,
            rect: textRect,
            context: context
        )
    }

    private func drawThinkingIndicator(
        entry: CodexTrajectoryTranscriptDisplayEntry,
        at y: CGFloat,
        context: CGContext
    ) {
        let palette = CodexAppServerAdaptivePalette(appearance: effectiveAppearance)
        let titleFont = currentTheme.style(for: .assistantText).font
        let lineHeight = ceil(CTFontGetAscent(titleFont) + CTFontGetDescent(titleFont) + CTFontGetLeading(titleFont))
        let textRect = CGRect(
            x: contentX,
            y: y + max(0, (thinkingIndicatorHeight - lineHeight) / 2),
            width: min(contentWidth, 260),
            height: lineHeight
        )
        drawAnimatedThinkingLine(
            entry.title,
            font: titleFont,
            baseColor: palette.secondaryText.withAlphaComponent(CodexThinkingGlint.baseAlpha),
            highlightColor: palette.primaryText.withAlphaComponent(1),
            rawPhase: thinkingAnimationPhase(),
            rect: textRect,
            context: context
        )
    }

    private func thinkingAnimationPhase() -> CGFloat {
        let elapsed = ProcessInfo.processInfo.systemUptime - thinkingAnimationStartTime
        return normalizedPhase(CGFloat((elapsed / CodexThinkingGlint.duration).truncatingRemainder(dividingBy: 1)))
    }

    private func normalizedPhase(_ value: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private func drawAnimatedThinkingLine(
        _ text: String,
        font: CTFont,
        baseColor: NSColor,
        highlightColor: NSColor,
        rawPhase: CGFloat,
        rect: CGRect,
        context: CGContext
    ) {
        drawTruncatedLine(text, font: font, color: baseColor.cgColor, rect: rect, context: context)
        drawThinkingSweep(
            text,
            font: font,
            color: highlightColor.withAlphaComponent(CodexThinkingGlint.highlightAlpha),
            rawPhase: rawPhase,
            rect: rect,
            context: context
        )
    }

    private func drawThinkingSweep(
        _ text: String,
        font: CTFont,
        color: NSColor,
        rawPhase: CGFloat,
        rect: CGRect,
        context: CGContext
    ) {
        guard rect.width > 1, rect.height > 1, !text.isEmpty else { return }
        let sweepWidth = max(18, rect.width * CodexThinkingGlint.sweepFraction)
        let easedPhase = CodexThinkingGlint.easedPhase(rawPhase)
        let sweepX = rect.minX - sweepWidth + easedPhase * (rect.width + sweepWidth * 2)
        let highlight = CodexAppServerAdaptivePalette.resolved(color, appearance: effectiveAppearance)
        let transparent = highlight.withAlphaComponent(0)
        let colors = [
            transparent.cgColor,
            highlight.cgColor,
            transparent.cgColor,
        ] as CFArray
        var locations: [CGFloat] = [0, 0.5, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: &locations
        ) else {
            return
        }

        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: highlight.cgColor,
        ]
        let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let tokenAttributed = CFAttributedStringCreate(kCFAllocatorDefault, "..." as CFString, attributes as CFDictionary)!
        let token = CTLineCreateWithAttributedString(tokenAttributed)
        let displayLine = CTLineCreateTruncatedLine(line, Double(rect.width), .end, token) ?? line
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        let baseline = max(descent, (rect.height - lineHeight) / 2 + descent)
        let localSweepX = sweepX - rect.minX

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.textPosition = CGPoint(x: 0, y: baseline)
        context.setTextDrawingMode(.clip)
        CTLineDraw(displayLine, context)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: localSweepX, y: rect.height / 2),
            end: CGPoint(x: localSweepX + sweepWidth, y: rect.height / 2),
            options: []
        )
        context.restoreGState()
    }

    private func drawAccordionHeader(
        entry: CodexTrajectoryTranscriptDisplayEntry,
        in rect: CGRect,
        context: CGContext
    ) {
        let palette = CodexAppServerAdaptivePalette(appearance: effectiveAppearance)
        let secondary = palette.secondaryText
        let primary = palette.primaryText

        let titleSize: CGFloat = entry.kind == .toolRun ? 14 : 13.5
        let titleFont = CTFontCreateUIFontForLanguage(.system, titleSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, titleSize, nil)
        let summaryFont = CTFontCreateUIFontForLanguage(.system, 14, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let statusFont = CTFontCreateUIFontForLanguage(.system, 11.5, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 11.5, nil)

        let isToolRun = entry.kind == .toolRun
        let textX = isToolRun ? rect.minX + AccordionChrome.toolRunLeadingInset : rect.minX
        let statusWidth: CGFloat = entry.statusText == nil ? 0 : 112
        let titleWidth = max(1, rect.maxX - textX - statusWidth - 28)
        drawTruncatedLine(
            entry.title,
            font: titleFont,
            color: (isToolRun ? primary.withAlphaComponent(0.88) : secondary).cgColor,
            rect: CGRect(x: textX, y: rect.minY + 4, width: titleWidth, height: 18),
            context: context
        )

        let measuredTitleWidth = min(titleWidth, measureTextWidth(entry.title, font: titleFont))
        let chevronCenter = isToolRun
            ? CGPoint(x: rect.minX + AccordionChrome.toolRunChevronX, y: rect.minY + AccordionChrome.titleChevronY)
            : CGPoint(
                x: textX + measuredTitleWidth + AccordionChrome.chevronTextGap,
                y: rect.minY + AccordionChrome.titleChevronY
            )
        drawChevron(
            progress: expansionProgress(for: entry.id),
            center: chevronCenter,
            color: secondary.withAlphaComponent(0.86).cgColor,
            context: context
        )

        if let statusText = entry.statusText {
            drawTruncatedLine(
                statusText,
                font: statusFont,
                color: secondary.cgColor,
                rect: CGRect(x: rect.maxX - statusWidth, y: rect.minY + 6, width: statusWidth, height: 16),
                context: context
            )
        }

        let visibleSummaries = Array(entry.toolSummaryLines.prefix(accordionSummaryLimit))
        var summaryY = rect.minY + accordionHeaderTitleHeight + 2
        for summary in visibleSummaries {
            drawTruncatedLine(
                summary,
                font: summaryFont,
                color: primary.withAlphaComponent(0.86).cgColor,
                rect: CGRect(
                    x: textX,
                    y: summaryY,
                    width: max(1, rect.width - 20),
                    height: accordionSummaryRowHeight
                ),
                context: context
            )
            summaryY += accordionSummaryRowHeight
        }
    }

    private func drawPreviousMessagesHeader(
        entry: CodexTrajectoryTranscriptDisplayEntry,
        in rect: CGRect,
        context: CGContext
    ) {
        let secondary = CodexAppServerAdaptivePalette(appearance: effectiveAppearance).secondaryText
        let font = CTFontCreateUIFontForLanguage(.system, 14, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 14, nil)

        drawTruncatedLine(
            entry.title,
            font: font,
            color: secondary.cgColor,
            rect: CGRect(x: rect.minX, y: rect.minY + 12, width: rect.width - 34, height: 22),
            context: context
        )

        let textWidth = min(rect.width - 34, measureTextWidth(entry.title, font: font))
        drawChevron(
            progress: expansionProgress(for: entry.id),
            center: CGPoint(x: rect.minX + textWidth + AccordionChrome.chevronTextGap + 4, y: rect.midY),
            color: secondary.withAlphaComponent(0.86).cgColor,
            context: context
        )
    }

    private func drawChevron(
        progress: CGFloat,
        center: CGPoint,
        color: CGColor,
        context: CGContext
    ) {
        AccordionChrome.drawChevron(
            progress: progress,
            center: center,
            color: color,
            context: context
        )
    }

    private func drawAccordionContentBackground(in rect: CGRect, context: CGContext) {
        let palette = CodexAppServerAdaptivePalette(appearance: effectiveAppearance)
        let fill = palette.surfaceFill
        let stroke = palette.stroke
        context.saveGState()
        context.setFillColor(fill.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        context.setStrokeColor(stroke.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.strokePath()
        context.restoreGState()
    }

    private func drawFileChangeCard(
        entry: CodexTrajectoryTranscriptDisplayEntry,
        in rect: CGRect,
        context: CGContext
    ) {
        guard !entry.fileChanges.isEmpty else { return }
        let fill = Self.fileChangeCardFill(for: effectiveAppearance)
        let stroke = Self.fileChangeCardStroke(for: effectiveAppearance)
        let palette = CodexAppServerAdaptivePalette(appearance: effectiveAppearance)
        let primary = palette.primaryText
        let secondary = palette.secondaryText
        let green = Self.color(.systemGreen, appearance: effectiveAppearance)
        let red = Self.color(.systemRed, appearance: effectiveAppearance)
        let titleFont = CTFontCreateUIFontForLanguage(.system, 14, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let rowFont = CTFontCreateUIFontForLanguage(.system, 14, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let countFont = CTFontCreateUIFontForLanguage(.system, 13, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 13, nil)

        context.saveGState()
        context.setFillColor(fill.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        context.setStrokeColor(stroke.withAlphaComponent(0.72).cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.strokePath()
        context.restoreGState()

        let horizontalPadding: CGFloat = 16
        let added = entry.fileChanges.reduce(0) { $0 + $1.added }
        let removed = entry.fileChanges.reduce(0) { $0 + $1.removed }
        let title = fileChangeTitle(count: entry.fileChanges.count)
        let undo = String(localized: "codexAppServer.fileChange.undo", defaultValue: "Undo")
        let undoWidth = measureTextWidth(undo, font: countFont) + 18
        drawSegmentedLine(
            [
                (title, titleFont, primary.cgColor),
                ("+\(added)", titleFont, green.cgColor),
                ("-\(removed)", titleFont, red.cgColor),
            ],
            rect: CGRect(
                x: rect.minX + horizontalPadding,
                y: rect.minY + 11,
                width: max(1, rect.width - horizontalPadding * 2 - undoWidth),
                height: 20
            ),
            spacing: 7,
            context: context
        )
        drawTruncatedLine(
            undo,
            font: countFont,
            color: primary.withAlphaComponent(0.88).cgColor,
            rect: CGRect(x: rect.maxX - horizontalPadding - undoWidth, y: rect.minY + 12, width: undoWidth - 10, height: 18),
            context: context
        )
        drawUndoArrow(
            center: CGPoint(x: rect.maxX - horizontalPadding - 5, y: rect.minY + 21),
            color: secondary.cgColor,
            context: context
        )

        var rowY = rect.minY + fileChangeHeaderHeight
        for change in entry.fileChanges {
            context.saveGState()
            context.setStrokeColor(stroke.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rowY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rowY))
            context.strokePath()
            context.restoreGState()

            let addedText = "+\(change.added)"
            let removedText = "-\(change.removed)"
            let removedWidth = max(34, measureTextWidth(removedText, font: countFont) + 4)
            let addedWidth = max(34, measureTextWidth(addedText, font: countFont) + 4)
            let countsWidth = addedWidth + removedWidth + 10
            drawTruncatedLine(
                CodexTrajectoryToolRun.displayPath(change.path),
                font: rowFont,
                color: primary.cgColor,
                rect: CGRect(
                    x: rect.minX + horizontalPadding,
                    y: rowY + 10,
                    width: max(1, rect.width - horizontalPadding * 2 - countsWidth),
                    height: 20
                ),
                context: context
            )
            drawTruncatedLine(
                addedText,
                font: countFont,
                color: green.cgColor,
                rect: CGRect(x: rect.maxX - horizontalPadding - countsWidth, y: rowY + 11, width: addedWidth, height: 18),
                context: context
            )
            drawTruncatedLine(
                removedText,
                font: countFont,
                color: red.cgColor,
                rect: CGRect(x: rect.maxX - horizontalPadding - removedWidth, y: rowY + 11, width: removedWidth, height: 18),
                context: context
            )
            rowY += fileChangeRowHeight
        }
    }

    private func drawUndoArrow(center: CGPoint, color: CGColor, context: CGContext) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.setStrokeColor(color)
        context.setLineWidth(1.35)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addArc(center: .zero, radius: 5, startAngle: CGFloat.pi * 0.05, endAngle: CGFloat.pi * 1.45, clockwise: true)
        context.move(to: CGPoint(x: -5.5, y: -1.5))
        context.addLine(to: CGPoint(x: -8.2, y: -1.1))
        context.addLine(to: CGPoint(x: -6.8, y: 1.5))
        context.strokePath()
        context.restoreGState()
    }

    private func fileChangeTitle(count: Int) -> String {
        if count == 1 {
            return String(localized: "codexAppServer.fileChange.one", defaultValue: "1 file changed")
        }
        let format = String(
            localized: "codexAppServer.fileChange.many",
            defaultValue: "%1$ld files changed"
        )
        return String(format: format, locale: Locale.current, count)
    }

    private func drawMessageHoverChromeIfNeeded(
        snapshot: MessageChromeSnapshot,
        context: CGContext
    ) {
        let isVisible = hoveredMessageKey == snapshot.key || copiedMessageKey == snapshot.key
        guard isVisible else { return }

        let font = hoverTimestampFont
        let palette = CodexAppServerAdaptivePalette(appearance: effectiveAppearance)
        let secondary = palette.secondaryText
        let isCopied = copiedMessageKey == snapshot.key
        let isCopyHovered = hoveredCopyKey == snapshot.key
        let isCopyPressed = pressedCopyKey == snapshot.key && isCopyHovered
        let fadeAlpha = hoveredMessageKey == snapshot.key
            ? messageHoverFadeAlpha(for: snapshot.key)
            : 0.94

        context.saveGState()
        context.setAlpha(fadeAlpha)
        if let timestampRect = snapshot.timestampRect {
            drawTruncatedLine(
                snapshot.timestampText,
                font: font,
                color: secondary.withAlphaComponent(0.90).cgColor,
                rect: timestampRect,
                context: context
            )
        }
        CodexTranscriptCopyIconButton.draw(
            in: snapshot.copyRect,
            isHovering: isCopyHovered,
            isPressed: isCopyPressed,
            isCopied: isCopied,
            appearance: effectiveAppearance,
            context: context
        )
        context.restoreGState()
    }

    private func drawVisibleMessageHoverChrome(in context: CGContext, range: Range<Int>) {
        for index in range {
            guard let snapshot = messageChromeSnapshotsByPageEntryIndex[index] else {
                continue
            }
            drawMessageHoverChromeIfNeeded(
                snapshot: snapshot,
                context: context
            )
        }
    }

    private func drawBackground(
        for kind: CodexTrajectoryBlockKind,
        in rect: CGRect,
        context: CGContext
    ) {
        guard kind == .userText || kind == .stderr || kind == .warning else { return }
        let fill = Self.backgroundColor(for: kind, appearance: effectiveAppearance)
        let radius: CGFloat = kind == .userText ? 18 : 8
        context.saveGState()
        context.setFillColor(fill.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        if kind == .stderr || kind == .warning {
            let stroke = kind == .stderr
                ? Self.stderrStrokeColor(for: effectiveAppearance)
                : Self.warningStrokeColor(for: effectiveAppearance)
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(1)
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()

        }
        context.restoreGState()
    }

    private func drawTruncatedLine(
        _ text: String,
        font: CTFont,
        color: CGColor,
        rect: CGRect,
        context: CGContext
    ) {
        guard rect.width > 1, rect.height > 1, !text.isEmpty else { return }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let tokenAttributed = CFAttributedStringCreate(kCFAllocatorDefault, "..." as CFString, attributes as CFDictionary)!
        let token = CTLineCreateWithAttributedString(tokenAttributed)
        let displayLine = CTLineCreateTruncatedLine(line, Double(rect.width), .end, token) ?? line
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        let baseline = max(descent, (rect.height - lineHeight) / 2 + descent)

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: baseline)
        CTLineDraw(displayLine, context)
        context.restoreGState()
    }

    private func drawSegmentedLine(
        _ segments: [(text: String, font: CTFont, color: CGColor)],
        rect: CGRect,
        spacing: CGFloat,
        context: CGContext
    ) {
        var x = rect.minX
        for segment in segments {
            let width = min(max(0, rect.maxX - x), measureTextWidth(segment.text, font: segment.font))
            guard width > 0 else { break }
            drawTruncatedLine(
                segment.text,
                font: segment.font,
                color: segment.color,
                rect: CGRect(x: x, y: rect.minY, width: width + 2, height: rect.height),
                context: context
            )
            x += width + spacing
        }
    }

    private func measureTextWidth(_ text: String, font: CTFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func pruneLayoutCache() {
        cachedLayouts = cachedLayouts.filter { key, _ in
            activeLayoutCacheKeys.contains(key)
        }
    }

    fileprivate static func transcriptBackgroundColor(for appearance: NSAppearance) -> NSColor {
        color(GhosttyBackgroundTheme.currentColor(), appearance: appearance)
    }

    private static func fileChangeCardFill(for appearance: NSAppearance) -> NSColor {
        CodexAppServerAdaptivePalette(appearance: appearance).elevatedSurfaceFill
    }

    private static func fileChangeCardStroke(for appearance: NSAppearance) -> NSColor {
        CodexAppServerAdaptivePalette(appearance: appearance).stroke
    }

    private static func theme(
        for appearance: NSAppearance,
        transcriptFontSize: CGFloat = CGFloat(CodexAppServerUISettings.defaultTranscriptFontSize)
    ) -> CodexTrajectoryTheme {
        let palette = CodexAppServerAdaptivePalette(appearance: appearance)
        let isDark = palette.isDark
        let textSize = CodexAppServerUISettings.clampedTranscriptFontSize(Double(transcriptFontSize))
        let monoSize = max(11, textSize - 1.5)
        let textFont = CTFontCreateUIFontForLanguage(.system, textSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, textSize, nil)
        let monoFont = CTFontCreateUIFontForLanguage(.userFixedPitch, monoSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, monoSize, nil)
        let primary = palette.primaryText
        let muted = palette.secondaryText
        let error = palette.errorText
        let fallback = CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary.cgColor)

        return CodexTrajectoryTheme(
            identifier: "\(isDark ? "cmux-dark" : "cmux-light")-\(Int((textSize * 10).rounded()))",
            contentInsets: CodexTrajectoryInsets(top: 4, left: 0, bottom: 4, right: 0),
            contentInsetsByKind: [
                .userText: CodexTrajectoryInsets(top: 8, left: 12, bottom: 8, right: 12),
                .stderr: CodexTrajectoryInsets(top: 10, left: 14, bottom: 10, right: 14),
                .warning: CodexTrajectoryInsets(top: 8, left: 14, bottom: 8, right: 12),
            ],
            stylesByKind: [
                .userText: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary.cgColor),
                .assistantText: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary.cgColor),
                .commandOutput: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: muted.cgColor),
                .toolCall: CodexTrajectoryBlockStyle(font: monoFont, foregroundColor: muted.cgColor),
                .fileChange: CodexTrajectoryBlockStyle(font: monoFont, foregroundColor: primary.cgColor),
                .approvalRequest: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary.cgColor),
                .status: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: muted.cgColor),
                .warning: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: color(Self.warningTextColor(for: appearance), appearance: appearance).cgColor),
                .stderr: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: color(error, appearance: appearance).cgColor),
                .systemEvent: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: muted.cgColor),
            ],
            fallbackStyle: fallback,
            markdownKinds: [.assistantText]
        )
    }

    private static func primaryTextColor(for appearance: NSAppearance) -> NSColor {
        CodexAppServerAdaptivePalette(appearance: appearance).primaryText
    }

    private static func backgroundColor(
        for kind: CodexTrajectoryBlockKind,
        appearance: NSAppearance
    ) -> NSColor {
        switch kind {
        case .userText:
            return CodexAppServerAdaptivePalette(appearance: appearance).userBubbleFill
        case .assistantText:
            return CodexAppServerAdaptivePalette(appearance: appearance).surfaceFill
        case .stderr:
            return CodexAppServerAdaptivePalette(appearance: appearance).errorFill
        case .warning:
            return Self.warningFillColor(for: appearance)
        case .commandOutput, .toolCall, .fileChange, .systemEvent, .status, .approvalRequest:
            return CodexAppServerAdaptivePalette(appearance: appearance).surfaceFill
        }
    }

    private static func stderrStrokeColor(for appearance: NSAppearance) -> NSColor {
        CodexAppServerAdaptivePalette(appearance: appearance).errorStroke
    }

    private static func stderrAccentColor(for appearance: NSAppearance) -> NSColor {
        CodexAppServerAdaptivePalette(appearance: appearance).errorText
    }

    private static func warningTextColor(for appearance: NSAppearance) -> NSColor {
        let palette = CodexAppServerAdaptivePalette(appearance: appearance)
        return palette.isDark
            ? NSColor(srgbRed: 0.92, green: 0.78, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.48, green: 0.30, blue: 0.04, alpha: 1)
    }

    private static func warningFillColor(for appearance: NSAppearance) -> NSColor {
        let palette = CodexAppServerAdaptivePalette(appearance: appearance)
        let base = palette.isDark
            ? NSColor(srgbRed: 0.22, green: 0.16, blue: 0.07, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 0.95, blue: 0.82, alpha: 1)
        return Self.blend(palette.background, base, fraction: palette.isDark ? 0.76 : 0.86)
    }

    private static func warningStrokeColor(for appearance: NSAppearance) -> NSColor {
        let palette = CodexAppServerAdaptivePalette(appearance: appearance)
        return palette.isDark
            ? NSColor(srgbRed: 0.46, green: 0.34, blue: 0.15, alpha: 1)
            : NSColor(srgbRed: 0.82, green: 0.58, blue: 0.18, alpha: 1)
    }

    private static func color(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        CodexAppServerAdaptivePalette.resolved(color, appearance: appearance)
    }

    private static func blend(_ from: NSColor, _ to: NSColor, fraction: CGFloat) -> NSColor {
        let from = from.usingColorSpace(.deviceRGB) ?? from
        let to = to.usingColorSpace(.deviceRGB) ?? to
        let fraction = min(1, max(0, fraction))
        return NSColor(
            srgbRed: from.redComponent + (to.redComponent - from.redComponent) * fraction,
            green: from.greenComponent + (to.greenComponent - from.greenComponent) * fraction,
            blue: from.blueComponent + (to.blueComponent - from.blueComponent) * fraction,
            alpha: from.alphaComponent + (to.alphaComponent - from.alphaComponent) * fraction
        )
    }
}
