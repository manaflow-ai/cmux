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
        let unavailable = context.needs(DaemonCapabilities.shared.resumeCommand)
        for id: ActionID in ["resumeCommandSet", "resumeCommandEdit"] {
            registry.bind(id, unavailable: unavailable, invoke: { invocation in
                guard let (surface, connection) = terminal(invocation, context) else { return }
                if let command = invocation["command"]?.stringValue {
                    return registry.track(change(.set(command), surface, connection))
                }
                ask(editing: id == "resumeCommandEdit", surface, connection, context)
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
        guard daemon.supports(DaemonCapabilities.shared.resumeCommand) else {
            return context.refuse(daemon.missingCapabilityMessage(DaemonCapabilities.shared.resumeCommand))
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

    /// Asks for the line (Edit starts from the stored one) and stores a
    /// non-empty answer; a failure shows as a sheet.
    private static func ask(editing: Bool, _ surface: SurfaceID, _ connection: DaemonConnection, _ context: AppActionContext) {
        let window = CloudHandlers.window(context)
        // task-owner: ends when the person answers the sheet and the daemon replies
        Task { @MainActor in
            let stored = editing ? try? await connection.request(TerminalResumeCommandRequest(.surface(surface))).command : nil
            CloudPresenter.askText(MiscHandlerStrings.resumeCommandTitle, initial: stored ?? "", button: MiscHandlerStrings.resumeCommandSave,
                                   in: window) { text in
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { @MainActor in
                    if let failure = await change(.set(text), surface, connection).value {
                        CloudPresenter.show(MiscHandlerStrings.resumeCommandTitle, failure.message, in: window)
                    }
                }
            }
        }
    }
}
