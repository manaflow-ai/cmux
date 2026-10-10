#if DEBUG
import CmuxNextRemoteBrowser
import CmuxNextRemoteView
import Foundation

/// Development builds only (cx-wb5.75): a real `cmux.rd/1` desktop host on
/// this Mac's loopback, such as an SSH tunnel to a Linux `cmux-rd host`.
/// Opt-in by environment, read when a `remote_view` tab for a loopback host
/// (`local`, `localhost`, 127.0.0.0/8) connects; the host `mock` stays the
/// test desktop and without the environment nothing changes:
/// - `CMUX_RD_DEBUG_PORT`: the loopback port the host (or tunnel) listens on.
/// - `CMUX_RD_DEBUG_TOKEN_FILE`: a file only this user can read with the
///   host's 64-hex session token on its first line (the value the host got
///   on `--token-fd`). The token goes only into the rd hello.
/// - `CMUX_RD_DEBUG_USER` (optional): the hello's user, the host's
///   `--owner`; this Mac's user name by default.
/// The hello offers the upstream media caps, so a host with a sink (for
/// example `--upstream-record DIR`) enables the share buttons.
struct RemoteViewDebugRdHost {
    let endpoint: RemoteRdLoopbackEndpoint
    let tokenFile: RemoteBrowserSecretFile
    let user: String

    /// Nil unless both variables are set and the port is a valid loopback port.
    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let portText = environment["CMUX_RD_DEBUG_PORT"], let port = UInt16(portText),
              let endpoint = RemoteRdLoopbackEndpoint(port: port),
              let path = environment["CMUX_RD_DEBUG_TOKEN_FILE"], !path.isEmpty else { return nil }
        self.endpoint = endpoint
        tokenFile = RemoteBrowserSecretFile(path: path)
        user = environment["CMUX_RD_DEBUG_USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
    }

    /// A transport for `record`'s desktop, not yet connected. Nil when the
    /// token file is unusable (logged) or the Rust core cannot allocate.
    func transport(for record: RemoteViewTabRecord) -> RemoteRdStreamTransport? {
        let token: String
        do {
            token = try tokenFile.read()
        } catch {
            NSLog("remote view: CMUX_RD_DEBUG_TOKEN_FILE %@ unusable: %@", tokenFile.path, String(describing: error))
            return nil
        }
        let hello = RemoteRdHello(
            user: user, install: "cmux-next-debug-\(ProcessInfo.processInfo.processIdentifier)",
            token: token, caps: Self.upstreamCaps
        )
        return RemoteRdStreamTransport(
            endpoint: endpoint, hello: hello, startKey: UUID().uuidString, control: record.mode == .control
        )
    }

    /// The rd caps that let the viewer send its microphone, camera or screen (rd change C4).
    static let upstreamCaps = ["up_media", "stream.open"]
}
#endif
