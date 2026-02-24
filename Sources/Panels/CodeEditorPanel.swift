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
        return name.isEmpty ? "Untitled" : name
    }

    var detectedLanguageName: String? {
        LanguageDetection.languageName(forFilePath: filePath)
    }

    var displayIcon: String? { "doc.text" }

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath

        do {
            self.initialContent = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            self.initialContent = ""
        }
    }

    func save() {
        guard let text = currentTextProvider?() else { return }
        do {
            try text.write(toFile: filePath, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            NSLog("[CodeEditorPanel] Failed to save \(filePath): \(error)")
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
}
