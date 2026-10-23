import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Set, Edit and Clear Resume Command on a terminal tab (`resume-command`):
/// the line the terminal's daemon types on its new prompt, without Return,
/// when it respawns the terminal after a daemon restart, an update or a
/// reboot (classic Resume Commands). A `command` argument (CLI, MCP) sets it
/// at once; without one Set and Edit ask for the line, Edit starting from the
/// stored one. The terminal's own daemon stores it, also for a terminal on
/// another machine.
enum ResumeCommandHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let unavailable = context.needs(DaemonCapability.resumeCommand.rawValue)
        for id: ActionID in ["resumeCommandSet", "resumeCommandEdit"] {
            registry.bind(id, unavailable: unavailable, invoke: { invocation in
                guard let (surface, connection) = terminal(invocation, context) else { return }
                if let command = invocation["command"]?.stringValue {
                    return registry.track(change(.set(command), surface, connection))
                }
                ask(id, editing: id == "resumeCommandEdit", invocation, surface, connection, context)
            })
        }
        registry.bind("resumeCommandClear", unavailable: unavailable, invoke: { invocation in
            guard let (surface, connection) = terminal(invocation, context) else { return }
            registry.track(change(.clear, surface, connection))
        })
    }

    /// The targeted or focused terminal tab and its own daemon's connection.
    private static func terminal(_ invocation: ActionInvocation, _ context: AppActionContext) -> (SurfaceID, DaemonConnection)? {
        guard let (tab, _) = context.daemonTab(invocation) else { return nil }
        guard tab.kind == .pty else { return context.refuse(RefusalStrings.notATerminal) }
        let daemon = context.services.machines.daemon(forTab: tab)
        guard daemon.supports(DaemonCapability.resumeCommand.rawValue) else {
            return context.refuse(daemon.missingCapabilityMessage(DaemonCapability.resumeCommand.rawValue))
        }
        guard let connection = daemon.connection else { return context.refuse(MiscHandlerStrings.daemonOffline) }
        return (tab.surface, connection)
    }

    private static func change(_ change: TerminalResumeCommandRequest.Change, _ surface: SurfaceID,
                               _ connection: DaemonConnection) -> ActionWork {
        Task {
            do {
                _ = try await connection.request(TerminalResumeCommandRequest(.surface(surface), change: change))
                return nil
            } catch {
                return ActionWorkFailure(RefusalStrings.describe(error))
            }
        }
    }

    /// Asks for the line as a Cmd-Shift-P step (Edit starts from the stored one); Return runs `id`
    /// again with it as `command`, which stores it.
    private static func ask(_ id: ActionID, editing: Bool, _ invocation: ActionInvocation, _ surface: SurfaceID,
                            _ connection: DaemonConnection, _ context: AppActionContext) {
        // task-owner: ends when the daemon replies with the stored line
        Task { @MainActor in
            let stored = editing ? try? await connection.request(TerminalResumeCommandRequest(.surface(surface))).command : nil
            context.services.registry.ask(id, invocation, ActionArgumentAsk(argument: "command", initialText: stored))
        }
    }
}
