import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTerminal

// Find (terminal via Ghostty search, browser via its find bar) and input
// sent through the daemon.
extension TerminalHandlers {
    static func bindFind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("find", invoke: { invocation in
            guard let (pane, content) = ctx.visibleContent(invocation) else { return }
            switch content {
            case .browser:
                guard let window = ctx.services.windowController(showing: pane) else { return }
                window.focus.send(.focusPane(pane.paneKey, source: .intent))
                window.focus.send(.focusTarget(.findBar, source: .intent))
            case .terminal(let entry):
                if let text = invocation["text"]?.stringValue, !text.isEmpty { return entry.session.surfaceView.search(text) }
                guard let window = pane.view.window ?? ctx.refuse(RefusalStrings.noWindowForFind) else { return }
                let initial = entry.session.model.search?.needle ?? selection(of: entry) ?? ""
                findPrompt(initial: initial, in: window) { entry.session.surfaceView.search($0) }
            }
        })
        registry.bind("findNext", invoke: { navigate($0, forward: true, ctx) })
        registry.bind("findPrevious", invoke: { navigate($0, forward: false, ctx) })
        registry.bind("hideFind", invoke: { invocation in
            guard let (_, content) = ctx.visibleContent(invocation) else { return }
            guard case .terminal(let entry) = content else { return ctx.refuse(RefusalStrings.browserFindClosesWithEscape) }
            entry.session.surfaceView.endSearch()
        })
        registry.bind("useSelectionForFind", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            guard let text = selection(of: entry) ?? ctx.refuse(RefusalStrings.nothingSelected) else { return }
            entry.session.surfaceView.search(text)
        })
    }

    /// Sheet asking for the text to find (the terminal has no find bar yet).
    private static func findPrompt(initial: String, in window: NSWindow, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = HandlerStrings.findTitle
        alert.addButton(withTitle: HandlerStrings.findConfirm)
        alert.addButton(withTitle: Strings.cancel)
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            completion(field.stringValue)
        }
    }

    private static func navigate(_ invocation: ActionInvocation, forward: Bool, _ ctx: AppActionContext) {
        guard let (_, content) = ctx.visibleContent(invocation) else { return }
        switch content {
        case .browser(let entry):
            entry.chrome.perform(forward ? .findNext : .findPrevious)
        case .terminal(let entry):
            let view = entry.session.surfaceView
            guard entry.session.model.search != nil else { return ctx.refuse(RefusalStrings.noActiveFind) }
            if forward { view.searchNext() } else { view.searchPrevious() }
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
        registry.bind("pasteLastScreenshot", invoke: { invocation in
            guard let url = latestScreenshot() ?? ctx.refuse(RefusalStrings.noScreenshot) else { return }
            send(shellQuoted(url.path), paste: true, invocation, ctx)
        })
        registry.bind("palette.terminalOpenDirectory", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard let cwd = tab.cwd ?? ctx.refuse(RefusalStrings.noWorkingDirectory) else { return }
            open(URL(fileURLWithPath: cwd, isDirectory: true), with: invocation["app"]?.stringValue, ctx)
        })
    }

    private static func send(_ text: String, paste: Bool, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
        guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
        let surface = tab.surface
        // The tab's own machine: a Cloud terminal's input goes over its link.
        ctx.services.daemon(for: pane).send("send") { try await $0.send(surface, text: text, paste: paste) }
    }

    /// Newest file in the macOS screenshot folder (`com.apple.screencapture location`, else Desktop).
    private static func latestScreenshot() -> URL? {
        let folder = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let images = Set(["png", "jpg", "jpeg", "heic", "tiff"])
        return files
            .filter { images.contains($0.pathExtension.lowercased()) }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Opens `directory` in Finder, or in `app` (a bundle id, app name, or path).
    private static func open(_ directory: URL, with app: String?, _ ctx: AppActionContext) {
        guard let app, !app.isEmpty else {
            NSWorkspace.shared.open(directory)
            return
        }
        let workspace = NSWorkspace.shared
        let candidates = [
            workspace.urlForApplication(withBundleIdentifier: app),
            app.hasSuffix(".app") ? URL(fileURLWithPath: app) : nil,
            URL(fileURLWithPath: "/Applications/\(app).app"),
            URL(fileURLWithPath: "/System/Applications/\(app).app"),
        ]
        guard let appURL = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? ctx.refuse(MiscHandlerStrings.appNotFound(app)) else { return }
        workspace.open([directory], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
