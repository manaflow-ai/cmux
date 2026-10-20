import CmuxNextActions
import CmuxNextDaemon

/// Set, Edit and Clear Resume Command (`terminal-resume-command-v1`): the
/// command a terminal's new shell runs when the terminal respawns after its
/// host was lost or restarts (Restart). The daemon stores it with the
/// terminal (`set-terminal-resume-command`) and shows it on the tab
/// (``TabModel/resumeCommand``), so the palette, the CLI
/// (`cmux terminal set-resume-command`) and MCP run this one path. Set takes
/// the command (the palette asks for it); Edit without one opens a prompt
/// with the current command; Clear refuses a terminal that has none.
enum TerminalResumeCommandHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let needs = ctx.needs(DaemonCapabilities.shared.terminalResumeCommand)
        registry.bind("resumeCommandSet", unavailable: needs, invoke: { invocation in
            guard let tab = terminalTab(invocation, ctx) else { return }
            guard let command = invocation["command"]?.stringValue else { return ctx.refuse(TerminalResumeCommandStrings.needsCommand) }
            store(command, on: tab, ctx)
        })
        registry.bind("resumeCommandEdit", unavailable: needs, invoke: { invocation in
            guard let tab = terminalTab(invocation, ctx) else { return }
            if let command = invocation["command"]?.stringValue { return store(command, on: tab, ctx) }
            // A script has no prompt to answer.
            if registry.isCapturingRefusal { return ctx.refuse(TerminalResumeCommandStrings.needsCommand) }
            let title = registry.title(for: "resumeCommandEdit") ?? ""
            CloudPresenter.askText(title, initial: tab.resumeCommand ?? "", button: TerminalResumeCommandStrings.save,
                                   in: CloudHandlers.window(ctx)) { text in
                guard let text else { return }
                store(text, on: tab, ctx)
            }
        })
        registry.bind("resumeCommandClear", unavailable: needs, invoke: { invocation in
            guard let tab = terminalTab(invocation, ctx) else { return }
            guard tab.resumeCommand != nil else { return ctx.refuse(TerminalResumeCommandStrings.none) }
            store(nil, on: tab, ctx)
        })
    }

    /// The targeted (or focused) tab, when it is a terminal.
    private static func terminalTab(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> TabModel? {
        guard let (tab, _) = ctx.daemonTab(invocation) else { return nil }
        guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
        return tab
    }

    /// Sends the command (nil or blank clears it) to the daemon holding `tab`;
    /// the tab shows the stored command from the daemon's next tree push.
    private static func store(_ command: String?, on tab: TabModel, _ ctx: AppActionContext) {
        let daemon = ctx.services.machines.daemon(forTab: tab), surface = tab.surface
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        guard daemon.connection != nil else { return ctx.refuse(MiscHandlerStrings.daemonOffline) }
        daemon.send("set-terminal-resume-command", onFailure: { failure in ctx.refuse(failure.message) }) {
            _ = try await $0.request(SetTerminalResumeCommandRequest(surface: surface, command: value))
        }
    }
}
