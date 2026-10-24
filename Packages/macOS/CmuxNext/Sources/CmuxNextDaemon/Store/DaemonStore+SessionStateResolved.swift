extension DaemonStore {
    /// Waits until the state resources' first snapshot arrived, or this daemon serves none
    /// (``SessionStateStore/known``), and says whether it did on this connection.
    ///
    /// False when the connection changed first: every ``DaemonConnectionChange`` (a connect, a drop, a
    /// shutdown, a connection marked failed, a run ended by `close()`) ends the wait, so it never outlives its
    /// connection; false at once when the task is cancelled. Event-driven: one waiter in the session store,
    /// no observation loop. A caller that waits for a later connection's state asks again.
    ///
    /// - Returns: Whether the session state is known.
    @discardableResult
    public func sessionStateResolved() async -> Bool {
        await session.resolved()
    }
}
