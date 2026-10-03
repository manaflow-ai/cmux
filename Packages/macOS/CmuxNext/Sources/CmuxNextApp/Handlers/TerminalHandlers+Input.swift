import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTerminal
import CmuxNextTerminalFind

// Find (the terminal's find bar over Ghostty search, the browser's find bar) and input
// sent through the daemon.
extension TerminalHandlers {
    static func bindFind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("find", invoke: { invocation in
            guard let (pane, content) = ctx.visibleContent(invocation) else { return }
            switch content {
            case .agent, .page:
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
            case .placeholder:
                return
            }
        })
        registry.bind("findNext", invoke: { navigate($0, forward: true, ctx) })
        registry.bind("findPrevious", invoke: { navigate($0, forward: false, ctx) })
        registry.bind("hideFind", invoke: { invocation in
            guard let (_, content) = ctx.visibleContent(invocation) else { return }
            guard case .terminal(let entry) = content else { return ctx.refuse(RefusalStrings.browserFindClosesWithEscape) }
            // A socket or CLI run leaves focus and the selection alone.
            entry.session.find.close(restoringFocus: invocation.allowsViewChange)
        })
        registry.bind("useSelectionForFind", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            guard let text = selection(of: entry) ?? ctx.refuse(RefusalStrings.nothingSelected) else { return }
            entry.session.find.open(seed: text, takeFocus: invocation.allowsViewChange)
        })
    }

    private static func navigate(_ invocation: ActionInvocation, forward: Bool, _ ctx: AppActionContext) {
        guard let (_, content) = ctx.visibleContent(invocation) else { return }
        switch content {
        case .agent, .page:
            return ctx.refuse(RefusalStrings.notATerminal)
        case .browser(let entry):
            entry.chrome.perform(forward ? .findNext : .findPrevious)
        case .terminal(let entry):
            // Opens the bar with the last query when it is closed.
            let direction: TerminalFindDirection = forward ? .next : .previous
            guard entry.session.find.navigate(direction, takeFocus: invocation.allowsViewChange) else {
                return ctx.refuse(RefusalStrings.noActiveFind)
            }
        case .placeholder:
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

    static func send(_ text: String, paste: Bool, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
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

    static func shellQuoted(_ path: String) -> String {
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
