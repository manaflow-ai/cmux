import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextVSCodeServer

/// VS Code (Inline): Open Folder in VS Code (Inline)… serves a folder from the app's one
/// `serve-web` server (`AppServices.vscodeServeWeb`) and opens it in a browser split to the right
/// of the focused pane; Stop and Restart VS Code Inline Server act on that server. The palette, the
/// File menu, the CLI and MCP (`action run`) all run these handlers.
///
/// A person picks the folder in an open panel that starts at the focused terminal's folder;
/// automation opens that folder directly.
enum VSCodeInlineHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.openFolderInVSCodeInline", run: { invocation in try openFolder(invocation, context: context) })
        registry.bind("palette.vscodeServeWebStop", run: { _ in
            let service = context.services.vscodeServeWeb
            Task { await service.stop() }
        })
        registry.bind("palette.vscodeServeWebRestart", run: { _ in
            let vscode = try installedVSCode()
            let service = context.services.vscodeServeWeb, registry = context.registry
            Task {
                do { _ = try await service.restart(vscode: vscode) } catch {
                    if let reason = VSCodeInlineStrings.failure(error) { registry.refuse(reason) }
                }
            }
        })
    }

    private static func openFolder(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let pane = try context.pane(invocation)
        guard context.services.daemon(for: pane.pane).isLocal else { throw ActionFailure(message: VSCodeInlineStrings.thisMacOnly) }
        let vscode = try installedVSCode()
        let folder = focusedFolder(invocation, context: context)
        let byPerson = invocation.origin == .user
        guard byPerson else {
            guard let folder else { throw ActionFailure(message: VSCodeInlineStrings.noFolder) }
            return serve(folder, vscode: vscode, beside: pane, byPerson: false, context: context)
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = VSCodeInlineStrings.panelTitle
        panel.prompt = VSCodeInlineStrings.panelPrompt
        panel.directoryURL = URL(fileURLWithPath: folder ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            serve(url.standardizedFileURL.path, vscode: vscode, beside: pane, byPerson: true, context: context)
        }
        if let window = context.activeWindow?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// Starts (or reuses) the server, then opens `folder` in a browser split beside `pane`.
    private static func serve(_ folder: String, vscode: URL, beside pane: PaneController, byPerson: Bool, context: AppActionContext) {
        let service = context.services.vscodeServeWeb, registry = context.registry
        Task {
            do {
                let url = try await service.url(vscode: vscode, openingFolder: folder)
                try BrowserHandlers.splitBrowser(from: pane, direction: .right, url: url, byPerson: byPerson, context: context)
            } catch let failure as ActionFailure {
                registry.refuse(failure.message)
            } catch {
                if let reason = VSCodeInlineStrings.failure(error) { registry.refuse(reason) }
            }
        }
    }

    /// The focused terminal's folder, if it reports one.
    private static func focusedFolder(_ invocation: ActionInvocation, context: AppActionContext) -> String? {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id), tab.kind == .pty,
              let cwd = tab.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), cwd.hasPrefix("/") else { return nil }
        return cwd
    }

    /// The installed VS Code app: by bundle id, else the usual install places; Insiders last.
    private static func installedVSCode() throws -> URL {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") { return url }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/Applications/Visual Studio Code.app", "\(home)/Applications/Visual Studio Code.app", "/Applications/Code.app"]
            where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let url = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCodeInsiders") { return url }
        throw ActionFailure(message: VSCodeInlineStrings.notInstalled)
    }
}
