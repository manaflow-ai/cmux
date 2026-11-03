public import CmuxNextDaemon

/// The app's pages reach this daemon over its loopback page listener (cmux-tui
/// spec/transports.md "App listener and page files"). An owner that started without it (the CLI
/// or an agent started it) opens it on `ws-listen`; an owner too old for `ws-listen` is handed
/// off to the bundled build, which starts with the listener. A page never waits on a listener
/// that will not come.
extension DaemonService {
    public enum PageListenerOutcome: Sendable, Equatable {
        /// The listener and its credential file exist now.
        case ready
        /// The owner is exiting for a handoff; its successor starts with the listener.
        case restarting
        /// An external daemon binary without `ws-listen`: the person must update it.
        case unsupported
    }

    /// Opens the page listener of this app's daemon when its credential file is missing.
    public func ensurePageListener() async throws -> PageListenerOutcome {
        guard let connection, let identity else { throw DaemonError.notConnected }
        if identity.supports(DaemonCapability.wsListen.rawValue) {
            let request = identity.supports(DaemonCapability.wsListenOrigins.rawValue)
                ? WsListenRequest(allowOrigins: Self.pageOrigins) : WsListenRequest(allowOrigin: Self.channelsPageOrigin)
            _ = try await connection.request(request)
            return .ready
        }
        if let handOff = pageListenerHandOff, await handOff(connection, identity) { return .restarting }
        return .unsupported
    }
}
