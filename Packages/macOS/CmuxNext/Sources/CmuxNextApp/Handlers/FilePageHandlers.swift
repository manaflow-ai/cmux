import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
import CmuxNextPalette
import CmuxNextSettings

/// The code editor page's actions (diff-host S7; the markdown page's are PageCommandHandlers').
/// Each sends its page command (``EditorPageCommand/forAction``) to the focused editor page; the
/// keys stay in the one key dispatcher, which offers them only while that page has the keyboard
/// (`codeEditorFocused`). The shared find actions reach the editor
/// through ``sendFind(_:_:_:)`` from their terminal and browser handlers.
enum FilePageHandlers {
    /// The shared actions bound elsewhere (TerminalHandlers' find) that also drive the editor.
    static let sharedFindActions: Set<String> = ["find", "findNext", "findPrevious", "useSelectionForFind", "hideFind"]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(services.viewers.markdownPages)
        services.pages.register(services.viewers.editorPages)
        services.pages.register(services.viewers.fileTrees)
        // The chat header's Files (cx-p4rt) shows this Mac's folders only: it opens files and checks
        // symlinks here, so a chat whose session runs on another machine gets no tree.
        services.agentTabs.openFiles = { [weak services] chat, folder, target in
            guard let services, let link = services.agentTabs.gitLink?(chat), link === services.agentGit.local else { return }
            services.viewers.fileTrees.openBeside(folder: URL(fileURLWithPath: folder), chat: chat, target: target, link: link)
        }
        // R96: a recovered draft of a local file opens as an unsaved edit (the launch notice's Open),
        // in the page of its file type (D11): a markdown file in the markdown page, others in the
        // code editor page. The page compares the file with the draft's base itself.
        services.recoveryDrafts.restoreHandler = { [weak services] draft in
            // task-owner: one restore per launch notice Open; it ends when the tab opens
            Task { @MainActor in
                guard let restore = await FilePageRecovery.restore(draft), let services,
                      let pane = services.windows.active?.focusedPane else { return }
                let pages = FilePageOpener.kind(for: restore.url) == .markdown
                    ? services.viewers.markdownPages : services.viewers.editorPages
                pages.open(restore.url, in: pane, focus: true, recoveredText: restore.text)
                // The file changed after the draft: say so; the draft stays unsaved changes.
                if restore.conflict, let window = services.windowController(showing: pane)?.window ?? pane.view.window {
                    _ = CmuxToastCenter.shared.show(CmuxToast(id: "file-recovery-conflict:\(restore.url.path)",
                                                              message: FilePageStrings.restoreConflict(restore.url.lastPathComponent),
                                                              duration: .seconds(12)), in: window)
                }
            }
        }
        // Open Recovered Draft… (R96): the drafts on disk as a palette page; the page reads them
        // when it opens, so the handler only shows it.
        let recoveredDrafts = ActionID(rawValue: RecoveredDraftPage.id)
        services.palette.sources.actionPages[recoveredDrafts] = { [weak services] in
            services.map { RecoveredDraftPage(store: $0.recoveryDrafts).spec }
        }
        registry.bindEffect(recoveredDrafts, effect: { [weak services] _ in
            guard let services else { return .done }
            services.palette.show(page: RecoveredDraftPage(store: services.recoveryDrafts).spec,
                                  relativeTo: context.activeWindow?.window)
            return .done
        })
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
        // Copies the defaults taken from another editor into cmux.json, as the person's own keys.
        registry.bind("fileEditor.importEditorSettings", run: { invocation in
            let settings = try SettingsHandlers.requireSettings(context)
            let look = services.viewers.editorPages.look
            let writer = SettingWriter(invocation.origin)
            registry.track(Task { @MainActor in
                guard let from = look.importedFrom?.name else { return ActionWorkFailure(FilePageStrings.noEditorSettings) }
                do {
                    let written = try await settings.copyEditorSettings(look.importedSection, by: writer)
                    if let window = services.windows.active?.window {
                        _ = CmuxToastCenter.shared.show(CmuxToast(id: "editor-settings-copied",
                                                                  message: FilePageStrings.editorSettingsCopied(written, from: from)), in: window)
                    }
                    return nil
                } catch {
                    return ActionWorkFailure(error.localizedDescription)
                }
            })
        })
        // The word wrap toggle is the `editor.wordWrap` setting (PAGE-PREFS); the page follows its look.
        registry.bind("toggleFileEditorWordWrap", run: { invocation in
            _ = try page(.editor, context, invocation)
            let look = services.viewers.editorPages.look
            let current = look.current()["settings"]?["wordWrap"]?.stringValue ?? "off"
            let writer = SettingWriter(invocation.origin)
            registry.track(Task { @MainActor in
                try? await look.setPreference(key: "editor.wordWrap", value: .string(current == "off" ? "on" : "off"), by: writer)
                return nil
            })
        })
    }

    /// The focused (or targeted) tab's page of `kind`.
    static func page(_ kind: FilePageKind, _ context: AppActionContext, _ invocation: ActionInvocation) throws -> PageWebView {
        guard let id = context.scope(invocation).tab?.id.rawValue, case let key = providerKey(id, context.services),
              LocalPageTab.page(of: key) == kind.page,
              let page = service(kind, context.services).pageView(key) else {
            throw ActionFailure(message: FilePageStrings.noFilePage)
        }
        return page
    }

    static func service(_ kind: FilePageKind, _ services: AppServices) -> FilePageService {
        kind == .markdown ? services.viewers.markdownPages : services.viewers.editorPages
    }

    /// The provider key of strip tab `id`: a store page tab's key, else the id (an app-only tab).
    static func providerKey(_ id: String, _ services: AppServices) -> String {
        services.pages.storeKey(of: id) ?? id
    }

    /// The local file a file page tab shows (Reveal in Finder, Open With), nil for remote files or other tabs.
    static func file(ofTab id: String, _ services: AppServices) -> URL? {
        let key = providerKey(id, services)
        return FilePageKind.allCases.lazy.compactMap { kind in
            LocalPageTab.page(of: key) == kind.page ? service(kind, services).localFile(key) : nil
        }.first
    }

    /// Sends a shared find action to a code editor or markdown page tab; false for any other page.
    static func sendFind(_ action: String, _ id: String, _ services: AppServices, text: String? = nil) -> Bool {
        let key = providerKey(id, services)
        guard let command = EditorPageCommand.forAction[action], let kind = FilePageKind.allCases.first(where: { LocalPageTab.page(of: key) == $0.page }),
              let page = service(kind, services).pageView(key) else { return false }
        return page.send(command: command, arguments: text.map { ["text": .string($0)] } ?? [:])
    }
}
