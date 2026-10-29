import AppKit
import CmuxNextPages
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextScreenshots
import CmuxNextTerminal
import CmuxNextTerminalFind
import CmuxNextCompatAppKit

// Find (the terminal's find bar over Ghostty search, the browser's find bar, the chat's) and input
// sent through the daemon.
extension TerminalHandlers {
    static func bindFind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("find", invoke: { invocation in
            // A focused internal page with its own search field (Settings,
            // Keyboard Shortcuts, Passwords) focuses and selects that field.
            // An untargeted run that may change the view (Cmd-F, the palette); a CLI run names its pane.
            if invocation.target == nil, invocation.allowsViewChange, let controller = ctx.services.windows.active,
               let page = ctx.services.keyRouter.focusedPage(in: controller),
               page.descriptor.ownsSearchField, page.send(command: "focusSearch") { return }
            guard let (pane, content) = ctx.visibleContent(invocation) else { return }
            if case .page = content, let key = pane.stripModel.selectedID?.rawValue,
               FilePageHandlers.sendFind("find", key, ctx.services, text: invocation["text"]?.stringValue) { return }
            switch content {
            case .agent(let view):
                // The chat's own find bar (Find in Chat).
                AgentPaneFind(view).run("find", takeFocus: invocation.allowsViewChange)
            case .page, .conversation:
                return ctx.refuse(RefusalStrings.notATerminal)
            case .browser:
                guard let window = ctx.services.windowController(showing: pane) else { return }
                window.focus.send(.focusPane(pane.paneKey, source: .intent))
                window.focus.send(.focusTarget(.findBar, source: .intent))
            case .terminal(let entry):
                let find = entry.session.find
                // The text argument, else the last query, else the selection.
                let seed = invocation["text"]?.stringValue ?? (find.query.isEmpty ? selection(of: entry) : nil)
                // A socket or CLI run shows the bar without taking the keyboard.
                find.open(seed: seed, takeFocus: invocation.allowsViewChange)
            case .placeholder, .notice:
                return
            }
        })
        registry.bind("findNext", invoke: { navigate($0, forward: true, ctx) })
        registry.bind("findPrevious", invoke: { navigate($0, forward: false, ctx) })
        registry.bind("hideFind", invoke: { invocation in
            guard let (pane, content) = ctx.visibleContent(invocation) else { return }
            if sendToFilePage("hideFind", pane, content, ctx) { return }
            if case .agent(let view) = content { return AgentPaneFind(view).run("hideFind", takeFocus: false) }
            guard case .terminal(let entry) = content else { return ctx.refuse(RefusalStrings.browserFindClosesWithEscape) }
            // A socket or CLI run leaves focus and the selection alone.
            entry.session.find.close(restoringFocus: invocation.allowsViewChange)
        })
        registry.bind("useSelectionForFind", invoke: { invocation in
            if let (pane, content) = ctx.visibleContent(invocation), sendToFilePage("useSelectionForFind", pane, content, ctx) { return }
            guard let entry = ctx.terminal(invocation) else { return }
            guard let text = selection(of: entry) ?? ctx.refuse(RefusalStrings.nothingSelected) else { return }
            entry.session.find.open(seed: text, takeFocus: invocation.allowsViewChange)
        })
    }

    /// A code editor page tab takes the shared find actions as its page commands (diff-host S7).
    private static func sendToFilePage(_ action: String, _ pane: PaneController, _ content: TabContent, _ ctx: AppActionContext) -> Bool {
        guard case .page = content, let key = pane.stripModel.selectedID?.rawValue else { return false }
        return FilePageHandlers.sendFind(action, key, ctx.services)
    }

    private static func navigate(_ invocation: ActionInvocation, forward: Bool, _ ctx: AppActionContext) {
        guard let (pane, content) = ctx.visibleContent(invocation) else { return }
        if sendToFilePage(forward ? "findNext" : "findPrevious", pane, content, ctx) { return }
        switch content {
        case .agent(let view):
            AgentPaneFind(view).run(forward ? "findNext" : "findPrevious", takeFocus: invocation.allowsViewChange)
        case .page, .conversation:
            return ctx.refuse(RefusalStrings.notATerminal)
        case .browser(let entry):
            entry.chrome.perform(forward ? .findNext : .findPrevious)
        case .terminal(let entry):
            // Opens the bar with the last query when it is closed.
            let direction: TerminalFindDirection = forward ? .next : .previous
            guard entry.session.find.navigate(direction, takeFocus: invocation.allowsViewChange) else {
                return ctx.refuse(RefusalStrings.noActiveFind)
            }
        case .placeholder, .notice:
            return
        }
    }

    static func bindInput(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("terminal.sendText", invoke: { invocation in
            guard let text = invocation["text"]?.stringValue ?? ctx.refuse(RefusalStrings.textArgumentRequired) else { return }
            send(text, paste: false, invocation, ctx)
        })
        registry.bind("sendCtrlFToTerminal", invoke: { send("\u{06}", paste: false, $0, ctx) })
        // Ctrl-L: the shell redraws at the top and the old screen stays in scrollback.
        registry.bind("clearScreenKeepScrollback", invoke: { send("\u{0C}", paste: false, $0, ctx) })
        // The folder read runs off the main actor (a Desktop holds thousands of files, or sits in iCloud).
        registry.bindEffect("pasteLastScreenshot", effect: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return .done }
            guard tab.kind == .pty else { return .refused(RefusalStrings.notATerminal) }
            let surface = tab.surface
            let daemon = ctx.services.daemon(for: pane)
            // action-wait-allow: the path to paste is known only after the screenshot folder is read
            return .waiting(.fileSystem) {
                guard let url = await latestScreenshot() else {
                    return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.noScreenshot)
                }
                let text = shellQuoted(url.path)
                return await daemon.failure("send") { try await $0.send(surface, text: text, paste: true) }
            }
        })
        registry.bindEffect("palette.terminalOpenDirectory", effect: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return .done }
            guard let cwd = tab.cwd else { return .refused(RefusalStrings.noWorkingDirectory) }
            return open(URL(fileURLWithPath: cwd, isDirectory: true), with: invocation["app"]?.stringValue, ctx)
        })
    }

    static func send(_ text: String, paste: Bool, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
        guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
        let surface = tab.surface
        // The tab's own machine: a Cloud terminal's input goes over its link.
        ctx.services.daemon(for: pane).send("send") { try await $0.send(surface, text: text, paste: paste) }
    }

    /// Newest picture in the macOS screenshot folder (`com.apple.screencapture location`, else Desktop).
    @concurrent
    nonisolated private static func latestScreenshot() async -> URL? {
        let folder = ScreenshotSourceDetector(environment: SystemScreenshotEnvironment()).systemFolder()
        return await ScreenshotFolderReader().newestPicture(in: folder)
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Opens `directory` in Finder, or in `app` (a bundle id, app name, or path), which Launch Services finds on
    /// the system lane.
    private static func open(_ directory: URL, with app: String?, _ ctx: AppActionContext) -> ActionEffect {
        guard let app, !app.isEmpty else {
            NSWorkspace.shared.openInBackground(directory)
            return .done
        }
        let queries = ctx.services.workspaceQueries
        // action-wait-allow: the app a name means is known only when Launch Services answers on the system lane; then it opens.
        return .waiting(.externalProcess) {
            guard let appURL = (try? await queries.value(LinkMenu.application(named: app), priority: .userBlocking)) ?? nil else {
                return ActionWorkFailure(MiscHandlerStrings.appNotFound(app))
            }
            NSWorkspace.shared.openInBackground([directory], withApplicationAt: appURL)
            return nil
        }
    }
}
