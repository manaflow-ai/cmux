import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextVSCodeServer
import CmuxNextWindowRules

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
        // Where they cannot run (another machine's pane or workspace, no VS Code) the rows leave the menus and palette.
        registry.gate(["palette.openFolderInVSCodeInline"], unlessFinds: { _ = try decide($0, beside: shownPane($0, context), context) })
        registry.gate(["palette.vscodeServeWebRestart"], unlessFinds: { _ = try installedVSCode() })
    }

    private static func openFolder(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let pane = try targetPane(invocation, context: context)
        let (open, vscode) = try decide(invocation, beside: pane, context)
        let folder = open?.folder
        if open?.decision == "serve", let folder { return serve(folder, vscode: vscode, beside: pane, byPerson: false, context: context) }
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
                let effect = try BrowserHandlers.splitBrowser(from: pane, direction: .right, url: url, byPerson: byPerson, context: context)
                registry.settle(effect, of: "palette.openFolderInVSCodeInline", ActionInvocation())
            } catch let failure as ActionFailure {
                registry.refuse(failure.message)
            } catch {
                if let reason = VSCodeInlineStrings.failure(error) { registry.refuse(reason) }
            }
        }
    }

    /// The Rust decision (cmux-window-rules `files::vscode_open`) beside `pane`: serve the terminal's folder, or ask in
    /// a panel that starts there, with the VS Code app it opens with; else why not. Changes nothing: with no pane (a
    /// workspace row's workspace no window shows) only the workspace's machine and VS Code decide; its terminal is read
    /// once the run shows it.
    private static func decide(_ invocation: ActionInvocation, beside pane: PaneController?, _ context: AppActionContext) throws
        -> (open: WindowRules.Open?, vscode: URL) {
        let workspace = pane == nil ? (try? context.workspace(invocation))?.model.id : nil
        let local = pane.map { context.services.daemon(for: $0.pane).isLocal }
            ?? workspace.flatMap { context.services.machines.daemon(forWorkspace: $0)?.isLocal } ?? true
        let vscode = local ? (try? installedVSCode()) : nil, shell = pane.flatMap { terminal(of: $0, invocation) }
        let facts = WindowRules.VSCodeFacts(local: local, installed: vscode != nil, byPerson: invocation.origin == .user || pane == nil,
                                            terminal: shell != nil, cwd: shell?.cwd)
        let open = WindowRules().vscodeOpen(facts), decision = open?.decision
        guard let vscode, decision == "serve" || decision == "panel" else {
            throw ActionFailure(message: decision == "thisMacOnly" ? VSCodeInlineStrings.thisMacOnly
                                    : decision == "notInstalled" ? VSCodeInlineStrings.notInstalled : VSCodeInlineStrings.noFolder)
        }
        return (open, vscode)
    }

    /// The pane the folder opens beside, if a window shows it: a workspace target's (the sidebar row's menu) focused
    /// pane, else the targeted or focused pane.
    private static func shownPane(_ invocation: ActionInvocation, _ context: AppActionContext) -> PaneController? {
        guard let target = invocation.target ?? invocation["workspace"]?.targetValue, target.kind == .workspace else {
            return try? context.pane(invocation)
        }
        guard let model = try? context.workspace(invocation).model else { return nil }
        return context.services.windows.controllers.first { $0.workspaceContent?.workspace === model }?.focusedPane
    }

    /// ``shownPane(_:_:)``, showing a workspace target no window shows first, where it lives, as a click on its row does.
    static func targetPane(_ invocation: ActionInvocation, context: AppActionContext) throws -> PaneController {
        if let pane = shownPane(invocation, context) { return pane }
        guard let target = invocation.target ?? invocation["workspace"]?.targetValue, target.kind == .workspace else {
            return try context.pane(invocation)
        }
        let model = try context.workspace(invocation).model, windows = context.services.windows
        if let state = windows.active?.state { windows.show(workspaceID: model.id, in: state) }
        guard let pane = shownPane(invocation, context) else { throw ActionFailure(message: RefusalStrings.notShownInAnyWindow(target.description)) }
        return pane
    }

    /// The targeted terminal tab, else `pane`'s selected one, if it is a terminal.
    private static func terminal(of pane: PaneController, _ invocation: ActionInvocation) -> TabModel? {
        let targeted = invocation.target.flatMap { $0.kind == .tab ? StripTabID($0.id) : nil }
        guard let id = targeted ?? pane.stripModel.selectedID, let tab = pane.tab(id), tab.kind == .pty else { return nil }
        return tab
    }

    /// The installed VS Code app (``VSCodeAppLocator``).
    private static func installedVSCode() throws -> URL {
        let found = VSCodeAppLocator { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.installed()
        guard let found else { throw ActionFailure(message: VSCodeInlineStrings.notInstalled) }
        return found
    }
}
