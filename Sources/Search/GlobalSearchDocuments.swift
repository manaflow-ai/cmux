import Foundation

enum GlobalSearchIndexingLimits {
    static let maxIndexedTextCharacters = 400_000
    static let maxIndexedTerminalScrollbackLines = 4_000
    static let terminalLineChunkSize = 4
}

@MainActor
struct GlobalSearchPanelContext {
    let windowID: UUID
    let windowTitle: String
    let workspaceID: UUID
    let workspaceTitle: String
    let panelID: UUID
    let panelTitle: String
    let panel: any Panel

    var location: String {
        "\(windowTitle) > \(workspaceTitle)"
    }
}

struct BrowserPagePayload: Decodable {
    let title: String
    let url: String
    let text: String
}

@MainActor
enum GlobalSearchDocuments {
    static func browseHit(for context: GlobalSearchPanelContext) -> SearchIndexHit {
        let kind: GlobalSearchKind
        switch context.panel.panelType {
        case .browser:
            kind = .browser
        case .markdown:
            kind = .markdown
        case .terminal:
            kind = .terminal
        case .filePreview, .rightSidebarTool:
            kind = .title
        }

        return SearchIndexHit(
            id: SearchIndexDocument.panelStableID(panelID: context.panelID, kind: kind, subtype: "browse"),
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            panelID: context.panelID,
            kind: kind,
            title: context.panelTitle,
            location: "",
            anchor: "panel",
            snippet: context.location,
            rank: 0,
            timestamp: .now
        )
    }

    static func titleDocument(for context: GlobalSearchPanelContext) -> SearchIndexDocument {
        let text = [
            context.windowTitle,
            context.workspaceTitle,
            context.panelTitle
        ].filter { !$0.isEmpty }.joined(separator: "\n")

        return SearchIndexDocument(
            id: SearchIndexDocument.panelStableID(panelID: context.panelID, kind: .title),
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            panelID: context.panelID,
            kind: .title,
            title: context.panelTitle,
            location: context.location,
            anchor: "title",
            text: text
        )
    }

    static func markdownDocument(for panel: MarkdownPanel, context: GlobalSearchPanelContext) -> SearchIndexDocument? {
        let title = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = cappedText([title, panel.filePath, panel.content].filter { !$0.isEmpty }.joined(separator: "\n"))
        guard !text.isEmpty else { return nil }

        return SearchIndexDocument(
            id: SearchIndexDocument.panelStableID(panelID: context.panelID, kind: .markdown),
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            panelID: context.panelID,
            kind: .markdown,
            title: title,
            location: panel.filePath,
            anchor: panel.filePath,
            text: text
        )
    }

    static func terminalDocuments(
        scrollback: String,
        context: GlobalSearchPanelContext
    ) -> [SearchIndexDocument] {
        let lines = normalizedTerminalScrollbackLines(scrollback)
        guard !lines.isEmpty else { return [] }

        var documents: [SearchIndexDocument] = []
        var chunkLines: [(lineNumber: Int, text: String)] = []

        func flushChunk() {
            guard !chunkLines.isEmpty else { return }
            let startLineNumber = chunkLines[0].lineNumber
            let endLineNumber = chunkLines[chunkLines.count - 1].lineNumber
            let chunkText = chunkLines
                .map { $0.text }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            defer { chunkLines.removeAll(keepingCapacity: true) }
            guard !chunkText.isEmpty else { return }

            let lineLabel: String
            if startLineNumber == endLineNumber {
                lineLabel = String(
                    localized: "globalSearch.terminal.lineLocation",
                    defaultValue: "Line \(startLineNumber)"
                )
            } else {
                lineLabel = String(
                    localized: "globalSearch.terminal.lineRangeLocation",
                    defaultValue: "Lines \(startLineNumber)-\(endLineNumber)"
                )
            }
            let location = [
                context.location,
                context.panelTitle,
                lineLabel
            ].filter { !$0.isEmpty }.joined(separator: " > ")

            documents.append(
                SearchIndexDocument(
                    id: SearchIndexDocument.terminalLineChunkStableID(
                        panelID: context.panelID,
                        startLineNumber: startLineNumber
                    ),
                    windowID: context.windowID,
                    workspaceID: context.workspaceID,
                    panelID: context.panelID,
                    kind: .terminal,
                    title: context.panelTitle,
                    location: location,
                    anchor: "line:\(startLineNumber)",
                    text: chunkText
                )
            )
        }

        for (offset, line) in lines.enumerated() {
            chunkLines.append((lineNumber: offset + 1, text: line))
            if chunkLines.count >= GlobalSearchIndexingLimits.terminalLineChunkSize {
                flushChunk()
            }
        }
        flushChunk()

        return documents
    }

    nonisolated static func normalizedTerminalScrollbackLines(_ scrollback: String) -> [String] {
        let normalized = strippedTerminalControlSequences(scrollback)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let cappedScrollback = cappedTailText(normalized)
        return cappedScrollback
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    nonisolated private static func strippedTerminalControlSequences(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        let scalars = text.unicodeScalars
        var index = scalars.startIndex

        func scalar(after scalarIndex: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index {
            scalars.index(after: scalarIndex)
        }

        func skipUntilStringTerminator(from startIndex: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index {
            var cursor = startIndex
            while cursor < scalars.endIndex {
                if scalars[cursor].value == 0x07 {
                    return scalar(after: cursor)
                }
                if scalars[cursor].value == 0x1B {
                    let next = scalar(after: cursor)
                    if next < scalars.endIndex, scalars[next] == "\\" {
                        return scalar(after: next)
                    }
                }
                cursor = scalar(after: cursor)
            }
            return cursor
        }

        while index < scalars.endIndex {
            guard scalars[index].value == 0x1B else {
                output.append(scalars[index])
                index = scalar(after: index)
                continue
            }

            let next = scalar(after: index)
            guard next < scalars.endIndex else { break }

            switch scalars[next] {
            case "[":
                index = scalar(after: next)
                while index < scalars.endIndex {
                    let value = scalars[index].value
                    index = scalar(after: index)
                    if (0x40...0x7E).contains(value) {
                        break
                    }
                }
            case "]", "P", "^", "_":
                index = skipUntilStringTerminator(from: scalar(after: next))
            default:
                index = scalar(after: next)
            }
        }

        return String(output)
    }

    nonisolated static func cappedText(_ text: String) -> String {
        guard text.count > GlobalSearchIndexingLimits.maxIndexedTextCharacters else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: GlobalSearchIndexingLimits.maxIndexedTextCharacters)
        return String(text[..<endIndex])
    }

    nonisolated static func cappedTailText(_ text: String) -> String {
        guard text.count > GlobalSearchIndexingLimits.maxIndexedTextCharacters else { return text }
        let startIndex = text.index(text.endIndex, offsetBy: -GlobalSearchIndexingLimits.maxIndexedTextCharacters)
        return String(text[startIndex...])
    }

    static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
