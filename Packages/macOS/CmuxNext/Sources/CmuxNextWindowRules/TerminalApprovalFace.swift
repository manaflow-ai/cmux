public import CmuxNextDaemon

/// A pair's terminal as its approval (``TerminalChatApproving``) reads it: the daemon's agent state for the
/// tab, its viewport's text and its keys, over the tab's daemon connection (the terminal may be hidden).
@MainActor public final class TerminalApprovalFace: TerminalApprovalTerminal {
    private weak var tab: TabModel?
    private let connection: @MainActor () -> DaemonConnection?

    /// `connection`: the tab's daemon's connection now (nil while it is down).
    public init(tab: TabModel, connection: @escaping @MainActor () -> DaemonConnection?) {
        self.tab = tab
        self.connection = connection
    }

    public var approvalBlocked: Bool { tab?.agent?.state == .blocked }

    public func approvalScreen() async -> String? {
        guard let tab, let connection = connection() else { return nil }
        return try? await connection.request(ReadScreenRequest(surface: tab.surface), timeout: .seconds(2)).text
    }

    /// Each key goes as its own write naming the program in the foreground now (`send-expect-foreground-v1`),
    /// so once the harness exits the daemon refuses the rest: an arrow and Enter never reach the shell, where
    /// they would run its last command again. Not `send-key`, which has no such check. A bare shell gets nothing.
    public func approvalPress(_ keys: [String]) async -> Bool {
        guard let tab, let connection = connection(), !keys.isEmpty else { return false }
        let bytes = keys.compactMap { Self.bytes[$0] }
        guard bytes.count == keys.count,
              let process = try? await connection.request(TerminalProcessInfoRequest(surface: tab.surface), timeout: .seconds(1)),
              process.runningProgram != nil, let program = process.foregroundExecutable else { return false }
        do {
            for key in bytes { try await connection.send(tab.surface, text: key, expectForeground: program) }
            return true
        } catch { return false }
    }

    /// What a terminal sends for each key a dialog's answer presses (normal cursor mode; Claude Code's and
    /// Codex's key readers take it in either mode).
    static let bytes = ["up": "\u{1b}[A", "down": "\u{1b}[B", "enter": "\r"]
}
