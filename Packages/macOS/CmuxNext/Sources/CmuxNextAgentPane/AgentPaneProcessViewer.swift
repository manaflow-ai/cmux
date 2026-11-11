public import Foundation

/// A background process's terminal (`chat.processTerminal`,
/// plans/cmux-next/background-task-terminal-DESIGN.md): what the App runs in a read-only terminal
/// tab beside a chat when a background task row is clicked. `acpmux process show --follow`
/// replays every byte the process printed from the first one, with its colors, and follows it
/// until it ends; `k` stops it and `q` closes the view.
///
/// Process methods are local to an acpmux's machine, so the viewer always runs on the chat's
/// machine: for a chat on this Mac, this Mac's acpmux; for a Cloud or SSH chat, a terminal on that
/// machine's daemon running that machine's own acpmux (``onChatMachine``).
public struct AgentPaneProcessViewer: Sendable, Equatable {
    /// The program and its arguments, run without a shell (nothing is quoted or expanded).
    public let argv: [String]
    /// The terminal's environment additions: the chat's acpmux socket only, never a token.
    public let environment: [String: String]
    /// The tab's title until the viewer sets the command as its title.
    public let title: String
    /// The chat session and the tool call that started the process.
    public let session: String
    public let toolCall: String
    /// Whether the viewer runs on the chat's own machine (a Cloud or SSH chat), in a terminal of
    /// the daemon that hosts the chat's tab, and reads that machine's acpmux.
    public let onChatMachine: Bool

    /// The viewer of the process tool call `toolCall` of chat `session` started, read from the
    /// acpmux `executable` serving `socket`. Nil when an id is not a plain token.
    public init?(executable: URL, socket: String, session: String, toolCall: String) {
        guard Self.isToken(session), Self.isToken(toolCall), !socket.isEmpty else { return nil }
        argv = [executable.path, "process", "show", "--follow", "--session", session, "--tool-call", toolCall]
        environment = ["ACPMUX_SOCKET": socket]
        title = String(localized: "agentPane.processTerminal.title", defaultValue: "Background task", bundle: .module)
        self.session = session
        self.toolCall = toolCall
        onChatMachine = false
    }

    /// The viewer for a chat on another machine, run by that machine's daemon: its own cmux binary
    /// (`~/.cmux/bin/cmux-tui` on a Cloud machine, `~/.cmux/bin/cmux` on an SSH one, else `acpmux`
    /// on its PATH) reads its own acpmux over its own socket, so the process methods stay local
    /// there. The ids are arguments of the script, never part of it. Nil when an id is not a plain token.
    public init?(onChatMachine session: String, toolCall: String) {
        guard Self.isToken(session), Self.isToken(toolCall) else { return nil }
        let show = #"process show --follow --session "$1" --tool-call "$2""#
        let script = #"for b in "$HOME/.cmux/bin/cmux-tui" "$HOME/.cmux/bin/cmux"; do [ -x "$b" ] && exec "$b" acp "#
            + show + #"; done; exec acpmux "# + show
        argv = ["/bin/sh", "-c", script, "acpmux", session, toolCall]
        environment = [:]
        title = String(localized: "agentPane.processTerminal.title", defaultValue: "Background task", bundle: .module)
        self.session = session
        self.toolCall = toolCall
        onChatMachine = true
    }

    /// Whether `id` is one an acpmux session or tool call id can be: 1 to 256 letters, digits
    /// and `-_.:`, so it can never read as an option or a second argument.
    public static func isToken(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && !id.hasPrefix("-")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.:".unicodeScalars.contains($0) }
    }

    /// `chat.processTerminal`'s answer for `model`: `{opened}`, or refused for a page with no
    /// chat, a New Tab page, a local chat without its daemon or a host without the hook. A chat on
    /// another machine gets the viewer on that machine; the App opens it only on the daemon that
    /// hosts the chat's tab there, else `opened` is false.
    @MainActor static func open(_ toolCall: String, in model: AgentPaneModel) -> [String: Any] {
        guard let session = model.sessionId, model.newTab == nil, let header = model.header,
              let viewer = model.remoteChat ? AgentPaneProcessViewer(onChatMachine: session, toolCall: toolCall)
                : model.transport.acpmuxSocket.flatMap({ socket in model.transport.acpmuxExecutable.flatMap {
                    AgentPaneProcessViewer(executable: $0, socket: socket, session: session, toolCall: toolCall) } }) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.processTerminal")
        }
        return AgentPaneReply.success(["opened": header.openProcess(viewer)])
    }
}
