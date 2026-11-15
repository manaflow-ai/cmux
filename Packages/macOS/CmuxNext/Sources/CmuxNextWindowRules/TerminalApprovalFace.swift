import CmuxNextDaemon

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

    public func approvalPress(_ keys: [String]) async -> Bool {
        guard let tab, let connection = connection() else { return false }
        return (try? await connection.sendKeys(tab.surface, keys)) != nil
    }
}
