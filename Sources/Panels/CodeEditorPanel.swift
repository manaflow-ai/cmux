import Foundation
import Combine

@MainActor
final class CodeEditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .codeEditor
    let workspaceId: UUID

    @Published var filePath: String
    @Published var isDirty: Bool = false
    private var isFocused: Bool = false

    /// Initial file content loaded from disk. Only used once to populate the text view.
    let initialContent: String

    /// Closure set by the view to provide the current text view contents on demand.
    var currentTextProvider: (() -> String)?

    var displayTitle: String {
        let name = (filePath as NSString).lastPathComponent
        return name.isEmpty ? String(localized: "codeEditor.untitled", defaultValue: "Untitled") : name
    }

    var detectedLanguageName: String? {
        LanguageDetection.languageName(forFilePath: filePath)
    }

    var displayIcon: String? { "doc.text" }

    init(workspaceId: UUID, filePath: String, content: String = "") {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.initialContent = content
    }

    static func load(workspaceId: UUID, filePath: String) async -> CodeEditorPanel {
        let content = await Task.detached {
            (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""
        }.value
        return await CodeEditorPanel(workspaceId: workspaceId, filePath: filePath, content: content)
    }

    func save() {
        guard let text = currentTextProvider?() else { return }
        let path = filePath
        Task.detached {
            do {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                await MainActor.run { self.isDirty = false }
            } catch {
                NSLog("[CodeEditorPanel] Failed to save \(path): \(error)")
            }
        }
    }

    func close() {
        // Cleanup handled by Workspace
    }

    func focus() {
        isFocused = true
    }

    func unfocus() {
        isFocused = false
    }

    func triggerFlash() {
        // No flash animation for code editor panels
    }
}
