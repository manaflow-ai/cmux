import Foundation

enum GlobalSearchIndexingLimits {
    static let maxIndexedTextCharacters = 400_000
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
        case .terminal, .filePreview, .rightSidebarTool, .customSidebar, .agentSession, .project,
             .extensionBrowser, .workspaceTodo, .cloudVMLoading:
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

    static func cappedText(_ text: String) -> String {
        guard text.count > GlobalSearchIndexingLimits.maxIndexedTextCharacters else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: GlobalSearchIndexingLimits.maxIndexedTextCharacters)
        return String(text[..<endIndex])
    }

    static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
