public import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextAgentPane
import Foundation

/// A terminal's text to an agent chat:
///
/// - `terminal.fixLastCommand`: the Fix chip a failed command shows, the palette and the terminal menu. The command,
///   its exit status, its output and its folder go to the chat, asking the agent to find the cause and fix it.
/// - `terminal.sendLastOutputToChat`: the same text without the ask.
/// - `terminal.sendSelectionToChat`: the terminal's selection as a fenced block.
///
/// The command and its output are read from the screen once, by the terminal's daemon
/// (`terminal-command-context-v1`), when the person asks; nothing runs per output line. The app injects how an
/// invocation names its terminal and where the text goes (the workspace's agent chat after its draft, else a new
/// chat beside the terminal); nothing is sent, the person reads it and presses Return:
///
/// ```swift
/// TerminalToChatActions(unavailable: needs(capability), terminal: lookUp, selection: selected, deliver: draft)
///     .bind(into: registry)
/// ```
@MainActor
public struct TerminalToChatActions {
    public static let fixID: ActionID = "terminal.fixLastCommand"
    public static let lastOutputID: ActionID = "terminal.sendLastOutputToChat"
    public static let selectionID: ActionID = "terminal.sendSelectionToChat"
    private let unavailable: @MainActor () -> String?
    private let terminal: @MainActor (ActionInvocation) -> (SurfaceID, DaemonConnection)?
    private let selection: @MainActor (ActionInvocation) -> String?
    private let deliver: @MainActor (String, ActionInvocation) -> Void

    /// - Parameter unavailable: Why Fix and Send Last Output cannot run up front (no daemon with
    ///   `terminal-command-context-v1`), or nil.
    /// - Parameter terminal: The invocation's terminal tab surface and its daemon's connection; nil after the lookup
    ///   refused, which ends the run.
    /// - Parameter selection: The invocation's terminal's selected text, or nil.
    /// - Parameter deliver: Puts Markdown in the chat for the invocation's terminal.
    public init(unavailable: @escaping @MainActor () -> String?,
                terminal: @escaping @MainActor (ActionInvocation) -> (SurfaceID, DaemonConnection)?,
                selection: @escaping @MainActor (ActionInvocation) -> String?,
                deliver: @escaping @MainActor (String, ActionInvocation) -> Void) {
        self.unavailable = unavailable
        self.terminal = terminal
        self.selection = selection
        self.deliver = deliver
    }

    /// Binds the three actions' handlers in `registry`.
    public func bind(into registry: ActionRegistry) {
        let (terminal, deliver, selection) = (terminal, deliver, selection)
        for (id, intent) in [(Self.fixID, TerminalCommandContextRequest.Intent.fix), (Self.lastOutputID, .context)] {
            registry.bindEffect(id, unavailable: unavailable, effect: { invocation in
                guard let (surface, connection) = terminal(invocation) else { return .done }
                // action-wait-allow: the command and its output are on the terminal daemon's screen; the chat shows them once read
                return .waiting(.externalProcess) {
                    do {
                        let answer = try await connection.request(TerminalCommandContextRequest(surface: surface, intent: intent))
                        guard let text = answer.context?.text else { return ActionWorkFailure(RefusalStrings.noCommandToSend) }
                        deliver(text, invocation)
                        return nil
                    } catch {
                        return ActionWorkFailure(RefusalStrings.describe(error))
                    }
                }
            })
        }
        registry.bindEffect(Self.selectionID, effect: { invocation in
            guard let text = AgentPaneSeed.terminalDraft(selection: selection(invocation)) else {
                return .refused(RefusalStrings.nothingSelected)
            }
            deliver(text, invocation)
            return .done
        })
    }
}

extension RefusalStrings {
    /// Fix or Send Last Output to Chat found no finished command on the terminal's screen.
    public static var noCommandToSend: String {
        text("handlers.misc.failed.noCommandToSend",
             "This terminal shows no finished command to send. A command must finish in a shell with shell integration.")
    }
}
