public import CmuxNextActions
public import CmuxNextDaemon
import Foundation

/// Run Last Command Again on a terminal tab (`terminal.runLastCommandAgain`, `terminal-last-command-v1`): the tab's
/// daemon names the newest command its shell finished, and the action types it on the prompt as a paste, without
/// Return, so the person runs it again with one key (as a freed shell's restored prompt offers it). It refuses while
/// another program holds the terminal, and when the daemon kept no finished command (recording off, incognito, none
/// yet).
///
/// The app injects how an invocation names its terminal, so the lookup (focus, explicit target, the tab's own
/// daemon and its capability check) stays with the app's other terminal actions:
///
/// ```swift
/// RunLastCommandActions(unavailable: needs(capability), terminal: { invocation in lookUp(invocation) })
///     .bind(into: registry)
/// ```
@MainActor
public struct RunLastCommandActions {
    /// The action's catalog id.
    public static let id: ActionID = "terminal.runLastCommandAgain"
    private let unavailable: @MainActor () -> String?
    private let terminal: @MainActor (ActionInvocation) -> (SurfaceID, DaemonConnection)?

    /// - Parameter unavailable: Why the action cannot run up front (no daemon with `terminal-last-command-v1`), or nil.
    /// - Parameter terminal: The invocation's terminal tab surface and its daemon's connection; nil after the lookup
    ///   refused (not a terminal, daemon offline or without `terminal-last-command-v1`), which ends the run.
    public init(unavailable: @escaping @MainActor () -> String?,
                terminal: @escaping @MainActor (ActionInvocation) -> (SurfaceID, DaemonConnection)?) {
        self.unavailable = unavailable
        self.terminal = terminal
    }

    /// Binds the action's handler in `registry`.
    public func bind(into registry: ActionRegistry) {
        let terminal = terminal
        registry.bindEffect(Self.id, unavailable: unavailable, effect: { invocation in
            // The lookup already reported its refusal (not a terminal, daemon offline).
            guard let (surface, connection) = terminal(invocation) else { return .done }
            // action-wait-allow: the line to type is the shell's own record in the daemon, and the shell's foreground decides whether it may be typed
            return .waiting(.externalProcess) { await Self.type(surface, connection) }
        })
    }

    /// Reads the last command and types it while the shell itself holds the terminal.
    private static func type(_ surface: SurfaceID, _ connection: DaemonConnection) async -> ActionWorkFailure? {
        do {
            let answer = try await connection.request(TerminalLastCommandRequest(.surface(surface)))
            guard let last = answer.lastCommand else { return ActionWorkFailure(RefusalStrings.noLastCommand) }
            let process = try await connection.request(TerminalProcessInfoRequest(surface: surface))
            if process.runningProgram != nil { return ActionWorkFailure(RefusalStrings.programRunning) }
            // The shell must still be in front when the daemon writes; Return is the person's.
            _ = try await connection.request(SendInputRequest(surface: surface, text: last.command, paste: true,
                                                              expectForeground: process.foregroundExecutable))
            return nil
        } catch {
            return ActionWorkFailure(RefusalStrings.describe(error))
        }
    }
}
