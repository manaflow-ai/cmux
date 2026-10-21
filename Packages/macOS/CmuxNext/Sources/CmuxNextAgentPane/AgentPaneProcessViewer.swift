public import Foundation

/// A background process's terminal (`chat.processTerminal`,
/// plans/cmux-next/background-task-terminal-DESIGN.md): what the App runs in a read-only terminal
/// tab beside a chat when a background task row is clicked. `acpmux process show --follow`
/// replays every byte the process printed from the first one, with its colors, and follows it
/// until it ends; `k` stops it and `q` closes the view.
///
/// Built only for a chat on this Mac: process methods are local to the daemon's machine.
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

    /// The viewer of the process tool call `toolCall` of chat `session` started, read from the
    /// acpmux `executable` serving `socket`. Nil when an id is not a plain token.
    public init?(executable: URL, socket: String, session: String, toolCall: String) {
        guard Self.isToken(session), Self.isToken(toolCall), !socket.isEmpty else { return nil }
        argv = [executable.path, "process", "show", "--follow", "--session", session, "--tool-call", toolCall]
        environment = ["ACPMUX_SOCKET": socket]
        title = String(localized: "agentPane.processTerminal.title", defaultValue: "Background task", bundle: .module)
        self.session = session
        self.toolCall = toolCall
    }

    /// Whether `id` is one an acpmux session or tool call id can be: 1 to 256 letters, digits
    /// and `-_.:`, so it can never read as an option or a second argument.
    public static func isToken(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && !id.hasPrefix("-")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.:".unicodeScalars.contains($0) }
    }

    /// `chat.processTerminal`'s answer for `model`: `{opened}`, or refused for a page with no
    /// chat, a New Tab page, a chat on another machine or a host without the hook.
    @MainActor static func open(_ toolCall: String, in model: AgentPaneModel) -> [String: Any] {
        guard let session = model.sessionId, model.newTab == nil, !model.remoteChat,
              let socket = model.transport.acpmuxSocket, let executable = model.transport.acpmuxExecutable,
              let header = model.header,
              let viewer = AgentPaneProcessViewer(executable: executable, socket: socket, session: session, toolCall: toolCall) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.processTerminal")
        }
        return AgentPaneReply.success(["opened": header.openProcess(viewer)])
    }
}
