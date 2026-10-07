public import CmuxLink
public import CmuxTerminalRenderCore

/// The terminal screen's banner follows the Mac's link session; scrollback
/// older than the READY's pages is fetched on demand.
extension LinkTerminalByteSource: TerminalConnectionReporting, TerminalHistoryLoading {
    public func connectionStates() async -> AsyncStream<TerminalConnectionState> {
        let states = await client.linkStates()
        let (stream, continuation) = AsyncStream<TerminalConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var last: TerminalConnectionState?
            for await state in states {
                let mapped = Self.connectionState(state)
                guard mapped != last else { continue }
                last = mapped
                continuation.yield(mapped)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func loadOlderHistory() async {
        await connection.loadOlderHistory()
    }

    public func historyStates() async -> AsyncStream<TerminalHistoryState> {
        await connection.historyStates()
    }

    /// Between generations (`idle`) a new session is made on the next attach,
    /// so the banner reads connecting, never offline.
    public static func connectionState(_ state: LinkState) -> TerminalConnectionState {
        switch state {
        case .idle, .connecting: .connecting
        case .connected, .degraded: .connected
        case .reconnecting(let attempt, _): .reconnecting(attempt: attempt)
        case .closed: .offline
        }
    }
}
