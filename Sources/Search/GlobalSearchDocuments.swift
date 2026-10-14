import Foundation

enum GlobalSearchIndexingLimits {
    static let maxIndexedTextCharacters = 400_000
    /// The same bound session snapshots use when they persist terminal scrollback.
    static let maxTerminalCaptureRows = SessionPersistencePolicy.maxScrollbackLinesPerTerminal
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
             .extensionBrowser, .simulator, .workspaceTodo, .coderouterGuide, .notifications, .cloudVMLoading, .mobilePairing, .accountSignIn, .cloudVPNSetup:
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

    /// An open agent session's transcript, indexed in place of the pane's
    /// scrollback. Nonisolated so the capture manager builds it (capping up
    /// to 400k characters) off the main actor.
    nonisolated static func agentSessionDocument(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID,
        location: String,
        source: AgentSessionSearchSource,
        title: String,
        transcriptText: String
    ) -> SearchIndexDocument {
        // The location already names the pane's directory, so the body is
        // only what was said; a leading path would open every snippet.
        // Newest messages sit at the end, so a cap keeps the end.
        let text = cappedTextKeepingEnd(transcriptText)

        return SearchIndexDocument(
            id: SearchIndexDocument.panelStableID(panelID: panelID, kind: .agentSession),
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            kind: .agentSession,
            title: title,
            location: location,
            // The row's label: which agent, in place of a generic kind name.
            anchor: source.agentKind.globalSearchDisplayName,
            text: text
        )
    }

    nonisolated static func cappedText(_ text: String) -> String {
        guard text.count > GlobalSearchIndexingLimits.maxIndexedTextCharacters else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: GlobalSearchIndexingLimits.maxIndexedTextCharacters)
        return String(text[..<endIndex])
    }

    /// A session row is titled by the pane it lives in, so searching for a
    /// pane finds a row with that pane's name on it: the pane's own title when
    /// it names something (a rename, or the agent's task title), otherwise the
    /// workspace's. Shell defaults ("lucas@host:~", "Terminal", a bare user
    /// name or path) and the agent's own name don't count as names.
    nonisolated static func agentSessionRowTitle(
        workspaceTitle: String,
        paneTitle: String,
        agentName: String,
        userName: String = NSUserName()
    ) -> String {
        let workspace = workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let pane = paneTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { "\u{2733}\u{2736}\u{273B}\u{273D}\u{2722}\u{273A}\u{2726}\u{2727}\u{2217}\u{27E2}\u{25D0}\u{25D1}\u{25D2}\u{25D3}\u{25CF} ".contains($0) }
        let isShellDefault = pane.isEmpty
            || pane.caseInsensitiveCompare("Terminal") == .orderedSame
            || pane.caseInsensitiveCompare(userName) == .orderedSame
            || pane.caseInsensitiveCompare(agentName) == .orderedSame
            || pane.caseInsensitiveCompare("Claude Code") == .orderedSame
            || (pane.contains("@") && pane.contains(":"))
            || pane.hasPrefix("~") || pane.hasPrefix("/")
        if !isShellDefault { return String(pane) }
        return workspace.isEmpty ? agentName : workspace
    }

    nonisolated static func cappedTextKeepingEnd(_ text: String) -> String {
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
