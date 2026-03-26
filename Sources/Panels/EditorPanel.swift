import Foundation
import Combine
import WebKit
import AppKit

/// A panel that provides a code editor using CodeMirror 6 in a WKWebView.
/// Supports syntax highlighting, Cmd+S save, and dirty state tracking.
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

    // MARK: - WebView

    let webView: WKWebView
    private var navigationDelegate: EditorNavigationDelegate?
    private var isClosed: Bool = false

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let handler = EditorMessageHandler()
        config.userContentController.add(handler, name: "editorBridge")

        let webView = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        handler.onSave = { [weak self] content, path in
            self?.handleSave(content: content, filePath: path)
        }
        handler.onDirtyChanged = { [weak self] dirty in
            self?.isDirty = dirty
            self?.updateDisplayTitle()
        }

        loadEditorHTML()
    }

    // MARK: - Panel Protocol

    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    func unfocus() {}

    func close() {
        isClosed = true
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "editorBridge")
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Editor Loading

    private func loadEditorHTML() {
        guard let htmlURL = Bundle.main.url(forResource: "editor", withExtension: "html") else {
            isFileUnavailable = true
            return
        }

        let navDelegate = EditorNavigationDelegate { [weak self] in
            self?.injectFileContent()
        }
        self.navigationDelegate = navDelegate
        webView.navigationDelegate = navDelegate

        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    private func injectFileContent() {
        guard let contentData = try? JSONSerialization.data(
            withJSONObject: (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? "",
            options: .fragmentsAllowed
        ), let jsonContent = String(data: contentData, encoding: .utf8) else {
            isFileUnavailable = true
            return
        }

        guard let pathData = try? JSONSerialization.data(
            withJSONObject: filePath,
            options: .fragmentsAllowed
        ), let jsonPath = String(data: pathData, encoding: .utf8) else {
            isFileUnavailable = true
            return
        }

        let isDarkMode = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let js = "cmuxEditorInit(\(jsonContent), \(jsonPath), \(isDarkMode))"
        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error {
                NSLog("EditorPanel: Failed to init editor: \(error)")
                self?.isFileUnavailable = true
            } else {
                self?.isFileUnavailable = false
            }
        }
    }

    // MARK: - Save

    private func handleSave(content: String, filePath: String) {
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            isDirty = false
            updateDisplayTitle()
            webView.evaluateJavaScript("cmuxEditorSetClean()") { _, _ in }
        } catch {
            NSLog("EditorPanel: Failed to save \(filePath): \(error)")
        }
    }

    private func updateDisplayTitle() {
        let filename = (filePath as NSString).lastPathComponent
        displayTitle = isDirty ? "\(filename) *" : filename
    }
}

// MARK: - Message Handler

private final class EditorMessageHandler: NSObject, WKScriptMessageHandler {
    var onSave: ((String, String) -> Void)?
    var onDirtyChanged: ((Bool) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            switch type {
            case "save":
                if let content = body["content"] as? String,
                   let filePath = body["filePath"] as? String {
                    self?.onSave?(content, filePath)
                }
            case "dirtyChanged":
                if let dirty = body["isDirty"] as? Bool {
                    self?.onDirtyChanged?(dirty)
                }
            default:
                break
            }
        }
    }
}

// MARK: - Navigation Delegate

private final class EditorNavigationDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
