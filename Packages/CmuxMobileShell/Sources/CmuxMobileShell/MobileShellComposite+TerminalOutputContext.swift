/// ``MobileShellComposite`` is the connection-side context for its carved-out
/// ``MobileTerminalOutputService``: it exposes the active RPC client, the
/// connected flag, workspace lookup, the Mac-connection-status markers, and
/// the auth-failure disconnect path. The witnesses live in the main class
/// body; this extension only declares the conformance.
extension MobileShellComposite: MobileTerminalOutputContext {
    var isTerminalOutputConnected: Bool {
        connectionState == .connected
    }
}
