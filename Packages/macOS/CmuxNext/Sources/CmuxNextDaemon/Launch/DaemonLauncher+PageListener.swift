import Foundation

extension DaemonLauncher {
    /// `server ensure --ws-loopback --ws-allow-origin <origin>,<origin>...` for the bundled binary with
    /// page origins (cx-hnmbt.2, cx-hnmbt.10): an owner `ensure` spawns opens its WebSocket listener on
    /// 127.0.0.1, mints its credential into `<socket>.websocket.json` (0600, never on argv) and admits
    /// the app's page origins, one list (cmux-tui spec/transports.md "App listener and page files").
    /// An external binary may lack the option, so it never gets it. A running owner keeps the
    /// listener it started with.
    static func pageListenerArguments(_ configuration: Configuration) -> [String] {
        let origins = configuration.webSocketPageOrigins
        guard configuration.binaryIsBundled, !origins.isEmpty else { return [] }
        return ["--ws-loopback", "--ws-allow-origin", origins.joined(separator: ",")]
    }
}
