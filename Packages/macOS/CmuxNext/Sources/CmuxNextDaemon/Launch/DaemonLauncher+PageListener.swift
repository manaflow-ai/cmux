import Foundation

extension DaemonLauncher {
    /// `server ensure --ws-loopback --ws-allow-origin <origin>` for the bundled binary with a page
    /// origin (cx-hnmbt.2): an owner `ensure` spawns opens its WebSocket listener on 127.0.0.1, mints
    /// its credential into `<socket>.websocket.json` (0600, never on argv) and admits the app's page
    /// origin (cmux-tui spec/transports.md "App listener and page files"). An external binary may
    /// lack the option, so it never gets it. A running owner keeps the listener it started with.
    static func pageListenerArguments(_ configuration: Configuration) -> [String] {
        guard configuration.binaryIsBundled, let origin = configuration.webSocketPageOrigin else { return [] }
        return ["--ws-loopback", "--ws-allow-origin", origin]
    }
}
