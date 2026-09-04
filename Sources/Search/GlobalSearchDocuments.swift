import CmuxArtifacts
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
    /// Builds one bounded SQLite document for a durable Artifacts record.
    ///
    /// The workspace id is kept in the existing indexed columns and the
    /// artifact UUID is encoded in the document id. This lets activation
    /// resolve ownership without overloading a panel id or trusting a row
    /// position.
    static func artifactDocument(
        for record: ArtifactRecord,
        windowID: UUID? = nil
    ) -> SearchIndexDocument? {
        guard let workspaceID = record.ownership.workspaceID.flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        let resolvedWindowID = windowID ?? workspaceID
        let title = firstNonEmpty(
            record.title,
            record.metadata["fileName"],
            record.metadata["sourceSurfaceTitle"],
            record.kind.rawValue
        ) ?? String(localized: "artifactsPane.title", defaultValue: "Artifacts")
        let location = firstNonEmpty(
            record.ownership.workspaceTitle,
            record.ownership.projectRoot,
            record.metadata["sourcePath"]
        ) ?? ""
        let metadataText = record.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        let text = cappedText([
            record.kind.rawValue,
            record.identityKey,
            record.copyValue,
            record.source.rawValue,
            location,
            metadataText,
            record.inlineContent ?? ""
        ].filter { !$0.isEmpty }.joined(separator: "\n"))
        guard !text.isEmpty else { return nil }
        return SearchIndexDocument(
            id: SearchIndexDocument.artifactStableID(record.id),
            windowID: resolvedWindowID,
            workspaceID: workspaceID,
            panelID: nil,
            kind: .artifact,
            title: title,
            location: location,
            anchor: record.id.uuidString,
            text: text,
            timestamp: record.lastSeenAt
        )
    }

    static func browseHit(for context: GlobalSearchPanelContext) -> SearchIndexHit {
        let kind: GlobalSearchKind
        switch context.panel.panelType {
        case .browser:
            kind = .browser
        case .markdown:
            kind = .markdown
        case .terminal, .filePreview, .rightSidebarTool, .customSidebar, .agentSession, .project,
             .extensionBrowser, .simulator, .workspaceTodo, .links, .notifications, .cloudVMLoading, .mobilePairing, .accountSignIn:
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
