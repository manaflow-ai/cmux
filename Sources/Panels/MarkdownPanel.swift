import Foundation

enum MarkdownPanelError: LocalizedError {
    case missingFileURL

    var errorDescription: String? {
        switch self {
        case .missingFileURL:
            return "No file path is associated with this Markdown panel."
        }
    }
}

@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .markdown
    private(set) var workspaceId: UUID

    @Published var fileURL: URL?
    @Published var text: String
    @Published var isPreviewMode: Bool

    private var lastSavedText: String

    var displayTitle: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        return "Markdown"
    }

    var displayIcon: String? { "doc.text" }

    var isDirty: Bool { text != lastSavedText }

    init(
        workspaceId: UUID,
        fileURL: URL? = nil,
        text: String = "",
        isPreviewMode: Bool = false,
        lastSavedText: String? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.fileURL = fileURL
        self.text = text
        self.isPreviewMode = isPreviewMode
        self.lastSavedText = lastSavedText ?? text
    }

    static func loadFromDisk(
        workspaceId: UUID,
        fileURL: URL,
        isPreviewMode: Bool = false
    ) throws -> MarkdownPanel {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return MarkdownPanel(
            workspaceId: workspaceId,
            fileURL: fileURL,
            text: content,
            isPreviewMode: isPreviewMode,
            lastSavedText: content
        )
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func save() throws {
        guard let fileURL else {
            throw MarkdownPanelError.missingFileURL
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        lastSavedText = text
    }

    func focus() {}

    func unfocus() {}

    func close() {}

    func triggerFlash() {}
}
