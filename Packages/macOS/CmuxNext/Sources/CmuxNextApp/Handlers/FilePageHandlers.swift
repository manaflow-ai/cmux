import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings

/// The code editor page's actions (diff-host S7; the markdown page's are PageCommandHandlers').
/// Each sends its page command (``EditorPageCommand/forAction``) to the focused editor page; the
/// keys stay in the one key dispatcher, which offers them only while that page has the keyboard
/// (`filePreviewFocused`). The shared find actions reach the editor
/// through ``sendFind(_:_:_:)`` from their terminal and browser handlers.
enum FilePageHandlers {
    /// The shared actions bound elsewhere (TerminalHandlers' find) that also drive the editor.
    static let sharedFindActions: Set<String> = ["find", "findNext", "findPrevious", "useSelectionForFind", "hideFind"]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(services.markdownPages)
        services.pages.register(services.editorPages)
        for (action, command) in EditorPageCommand.forAction where !sharedFindActions.contains(action) {
            registry.bind(ActionID(rawValue: action), run: { invocation in
                var arguments: [String: JSONValue] = [:]
                if command == EditorPageCommand.editorAction {
                    guard let id = invocation["text"]?.stringValue, !id.isEmpty else {
                        throw ActionFailure(message: RefusalStrings.textArgumentRequired)
                    }
                    arguments["text"] = .string(id)
                }
                try page(.editor, context, invocation).send(command: command, arguments: arguments)
            })
        }
        // The word wrap toggle is the `editor.wordWrap` setting (PAGE-PREFS); the page follows its look.
        registry.bind("toggleFileEditorWordWrap", run: { invocation in
            _ = try page(.editor, context, invocation)
            let look = services.editorPages.look
            let current = look.current()["settings"]?["wordWrap"]?.stringValue ?? "off"
            registry.track(Task { @MainActor in
                try? await look.setPreference(key: "editor.wordWrap", value: .string(current == "off" ? "on" : "off"))
                return nil
            })
        })
    }

    /// The focused (or targeted) tab's page of `kind`.
    static func page(_ kind: FilePageKind, _ context: AppActionContext, _ invocation: ActionInvocation) throws -> PageWebView {
        guard let key = context.scope(invocation).tab?.id.rawValue, LocalPageTab.page(of: key) == kind.page,
              let page = service(kind, context.services).pageView(key) else {
            throw ActionFailure(message: FilePageStrings.noFilePage)
        }
        return page
    }

    static func service(_ kind: FilePageKind, _ services: AppServices) -> FilePageService {
        kind == .markdown ? services.markdownPages : services.editorPages
    }

    /// The file a file page tab shows (Reveal in Finder, Open With), nil for any other tab.
    static func file(ofTab key: String, _ services: AppServices) -> URL? {
        FilePageKind.allCases.lazy.compactMap { kind in
            LocalPageTab.page(of: key) == kind.page ? service(kind, services).file(key) : nil
        }.first
    }

    /// Sends a shared find action to an editor page tab; false for any other page.
    static func sendFind(_ action: String, _ key: String, _ services: AppServices, text: String? = nil) -> Bool {
        guard LocalPageTab.page(of: key) == .editor, let command = EditorPageCommand.forAction[action],
              let page = services.editorPages.pageView(key) else { return false }
        return page.send(command: command, arguments: text.map { ["text": .string($0)] } ?? [:])
    }
}
