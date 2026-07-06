import Foundation
import CmuxSidebar

enum GlobalSearchIndexingLimits {
    static let maxIndexedTextCharacters = 400_000
    static let maxWorkspaceMetadataCharacters = 16_000
    static let maxTranscriptChunkCharacters = 24_000
    static let maxCommandOutputCharacters = 4_000
    static let maxCommandChunkCharacters = 24_000
    static let maxTranscriptChunksPerSession = 40
    static let maxTrackedTranscriptSessions = 64
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
struct GlobalSearchWorkspaceMetadataContext {
    let windowID: UUID
    let windowTitle: String
    let workspaceID: UUID
    let workspaceTitle: String
    let workspace: Workspace

    var location: String {
        "\(windowTitle) > \(workspaceTitle)"
    }
}

struct GlobalSearchWorkspaceMetadataPanelSnapshot: Sendable, Equatable {
    let id: UUID
    let title: String
    let directory: String?
    let gitBranch: SidebarGitBranchState?
    let pullRequest: SidebarPullRequestState?
}

struct GlobalSearchWorkspaceMetadataSnapshot: Sendable, Equatable {
    let currentDirectory: String
    let workspaceGitBranch: SidebarGitBranchState?
    let workspacePullRequest: SidebarPullRequestState?
    let statusEntries: [SidebarStatusEntry]
    let progress: SidebarProgressState?
    let metadataBlocks: [SidebarMetadataBlock]
    let logEntries: [SidebarLogEntry]
    let panels: [GlobalSearchWorkspaceMetadataPanelSnapshot]
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
        case .terminal, .filePreview, .rightSidebarTool, .customSidebar, .agentSession, .project, .extensionBrowser:
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

    static func workspaceMetadataDocument(for context: GlobalSearchWorkspaceMetadataContext) -> SearchIndexDocument {
        workspaceMetadataDocument(
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            workspaceTitle: context.workspaceTitle,
            location: context.location,
            snapshot: workspaceMetadataSnapshot(for: context.workspace)
        )
    }

    static func workspaceMetadataDocument(
        windowID: UUID,
        workspaceID: UUID,
        workspaceTitle: String,
        location: String,
        snapshot: GlobalSearchWorkspaceMetadataSnapshot
    ) -> SearchIndexDocument {
        let text = cappedText(
            workspaceMetadataText(workspaceTitle: workspaceTitle, snapshot: snapshot),
            limit: GlobalSearchIndexingLimits.maxWorkspaceMetadataCharacters
        )

        return SearchIndexDocument(
            id: workspaceMetadataDocumentID(workspaceID: workspaceID),
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: nil,
            kind: .workspace,
            title: workspaceTitle,
            location: location,
            anchor: "workspace",
            text: text
        )
    }

    nonisolated static func workspaceMetadataDocumentID(workspaceID: UUID) -> String {
        "workspace:\(workspaceID.uuidString):metadata"
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

    nonisolated static func cappedText(
        _ text: String,
        limit: Int = GlobalSearchIndexingLimits.maxIndexedTextCharacters
    ) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex])
    }

    nonisolated static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func workspaceMetadataSnapshot(for workspace: Workspace) -> GlobalSearchWorkspaceMetadataSnapshot {
        let orderedPanelIDs = workspace.sidebarOrderedPanelIds()
        var seenPanelIDs = Set<UUID>()
        let remainingPanelIDs = workspace.panels.keys
            .filter { !orderedPanelIDs.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
        let panelSnapshots = (orderedPanelIDs + remainingPanelIDs).compactMap { panelID -> GlobalSearchWorkspaceMetadataPanelSnapshot? in
            guard seenPanelIDs.insert(panelID).inserted else { return nil }
            let panel = workspace.panels[panelID]
            let title = workspace.panelCustomTitles[panelID]
                ?? workspace.panelTitles[panelID]
                ?? panel?.displayTitle
                ?? ""
            return GlobalSearchWorkspaceMetadataPanelSnapshot(
                id: panelID,
                title: title,
                directory: workspace.panelDirectories[panelID],
                gitBranch: workspace.panelGitBranches[panelID],
                pullRequest: workspace.panelPullRequests[panelID]
            )
        }

        return GlobalSearchWorkspaceMetadataSnapshot(
            currentDirectory: workspace.currentDirectory,
            workspaceGitBranch: workspace.gitBranch,
            workspacePullRequest: workspace.pullRequest,
            statusEntries: workspace.statusEntries.values.sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                return lhs.key < rhs.key
            },
            progress: workspace.progress,
            metadataBlocks: workspace.sidebarMetadataBlocksInDisplayOrder(),
            logEntries: Array(workspace.logEntries.suffix(50)),
            panels: panelSnapshots
        )
    }

    private static func workspaceMetadataText(
        workspaceTitle: String,
        snapshot: GlobalSearchWorkspaceMetadataSnapshot
    ) -> String {
        var lines: [String] = []
        appendLine(label: "workspace title", value: workspaceTitle, to: &lines)
        appendLine(label: "workspace cwd", value: snapshot.currentDirectory, to: &lines)
        appendBranch(snapshot.workspaceGitBranch, label: "workspace git branch", to: &lines)
        appendPullRequest(snapshot.workspacePullRequest, label: "workspace pull request", to: &lines)
        for status in snapshot.statusEntries {
            appendLine(label: "status \(status.key)", value: status.value, to: &lines)
            appendLine(label: "status url \(status.key)", value: status.url?.absoluteString, to: &lines)
        }
        appendLine(label: "progress", value: snapshot.progress?.label, to: &lines)
        for block in snapshot.metadataBlocks {
            appendLine(label: "metadata \(block.key)", value: block.markdown, to: &lines)
        }
        for logEntry in snapshot.logEntries {
            appendLine(label: "log", value: logEntry.message, to: &lines)
            appendLine(label: "log source", value: logEntry.source, to: &lines)
        }
        for panel in snapshot.panels {
            appendLine(label: "panel title", value: panel.title, to: &lines)
            appendLine(label: "panel cwd", value: panel.directory, to: &lines)
            appendBranch(panel.gitBranch, label: "panel git branch", to: &lines)
            appendPullRequest(panel.pullRequest, label: "panel pull request", to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendLine(label: String, value: String?, to lines: inout [String]) {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return
        }
        lines.append("\(label): \(trimmed)")
    }

    private static func appendBranch(_ branch: SidebarGitBranchState?, label: String, to lines: inout [String]) {
        guard let branch else { return }
        appendLine(label: label, value: branch.branch, to: &lines)
        if branch.isDirty {
            appendLine(label: "\(label) state", value: "dirty", to: &lines)
        }
    }

    private static func appendPullRequest(
        _ pullRequest: SidebarPullRequestState?,
        label: String,
        to lines: inout [String]
    ) {
        guard let pullRequest else { return }
        appendLine(label: "\(label) number", value: "#\(pullRequest.number)", to: &lines)
        appendLine(label: "\(label) repository", value: pullRequest.label, to: &lines)
        appendLine(label: "\(label) url", value: pullRequest.url.absoluteString, to: &lines)
        appendLine(label: "\(label) status", value: pullRequest.status.rawValue, to: &lines)
        appendLine(label: "\(label) branch", value: pullRequest.branch, to: &lines)
        if pullRequest.isStale {
            appendLine(label: "\(label) state", value: "stale", to: &lines)
        }
    }
}
