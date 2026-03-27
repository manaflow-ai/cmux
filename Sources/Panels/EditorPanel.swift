import Foundation
import Combine
import AppKit

/// A panel that provides a plain text editor using native NSTextView.
/// No external dependencies — just reads a file, shows it in a monospace editor,
/// and saves on Cmd+S.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Absolute path to the file being edited.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Title shown in the tab bar (filename, with * when dirty).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.text" }

    /// Whether the editor has unsaved changes.
    @Published private(set) var isDirty: Bool = false

    /// Whether the file was loaded successfully.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// The text content — bound to the NSTextView via the view.
    @Published var content: String = ""

    /// Content at the time of last save, for dirty tracking.
    private var savedContent: String = ""

    private var isClosed: Bool = false

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        NSLog("EditorPanel: init for \(filePath)")

        do {
            let text = try String(contentsOfFile: filePath, encoding: .utf8)
            self.content = text
            self.savedContent = text
            self.isFileUnavailable = false
            NSLog("EditorPanel: loaded \(text.count) chars from \(filePath)")
        } catch {
            NSLog("EditorPanel: FAILED to read \(filePath): \(error)")
            self.isFileUnavailable = true
        }
    }

    // MARK: - Panel Protocol

    func focus() {
        // Focus is handled by the NSTextView in the view layer
    }

    func unfocus() {}

    func close() {
        isClosed = true
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Save

    func save() {
        NSLog("EditorPanel: save() called for \(filePath)")
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            savedContent = content
            isDirty = false
            updateDisplayTitle()
            NSLog("EditorPanel: saved OK (\(content.count) chars)")
        } catch {
            NSLog("EditorPanel: save FAILED: \(error)")
        }
    }

    /// Called by the view when text changes.
    func textDidChange() {
        let nowDirty = content != savedContent
        if nowDirty != isDirty {
            isDirty = nowDirty
            updateDisplayTitle()
        }
    }

    private func updateDisplayTitle() {
        let filename = (filePath as NSString).lastPathComponent
        displayTitle = isDirty ? "\(filename) *" : filename
    }
}
