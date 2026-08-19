import Foundation

enum GlobalSearchIndexingLimits {
    static let maxIndexedTextCharacters = 400_000
    /// Mirrors `SessionPersistencePolicy.maxScrollbackLinesPerTerminal`: the
    /// same bound session snapshots use when they persist terminal scrollback.
    static let maxTerminalCaptureRows = 4000
    /// Byte ceiling for the VT reconstruction Ghostty formats for those rows.
    /// Generous against escape sequences while keeping one capture bounded;
    /// the scrollback itself defaults to 50 MB (`GhosttyConfig.scrollbackLimit`).
    static let maxTerminalCaptureVTBytes = 1_500_000
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
        case .filePreview, .rightSidebarTool, .customSidebar, .agentSession, .project,
             .extensionBrowser, .simulator, .workspaceTodo, .notifications, .cloudVMLoading, .mobilePairing, .accountSignIn:
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

    static func terminalDocument(for context: GlobalSearchPanelContext, text: String) -> SearchIndexDocument? {
        let capped = cappedText(text)
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return SearchIndexDocument(
            id: SearchIndexDocument.panelStableID(panelID: context.panelID, kind: .terminal),
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            panelID: context.panelID,
            kind: .terminal,
            title: context.panelTitle,
            location: context.location,
            anchor: "terminal",
            text: capped
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
