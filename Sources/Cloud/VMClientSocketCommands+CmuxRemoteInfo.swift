import Foundation

extension TerminalController {
    /// The `vm.cmux_remote_info` result shape, shared by the attach-endpoint answer
    /// and the answer from a create receipt cached in this process.
    nonisolated static func cmuxRemoteInfoPayload(
        route: String,
        token: String,
        expiresAtUnix: Int64,
        session: String,
        trustedCarrier: Bool,
        daemonBuild: VMCmuxRemoteEndpoint.DaemonBuild?,
        networkAddresses: VMCmuxRemoteEndpoint.NetworkAddresses?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "transport": "cmux-remote",
            "route": route,
            "token": token,
            "expires_at_unix": expiresAtUnix,
            "session": session,
            "trusted_carrier": trustedCarrier
        ]
        if let daemonBuild {
            var raw: [String: Any] = [:]
            if let commit = daemonBuild.commit { raw["commit"] = commit }
            if let remoteProtocol = daemonBuild.remoteProtocol { raw["remote_protocol"] = remoteProtocol }
            if let version = daemonBuild.version { raw["version"] = version }
            payload["daemon_build"] = raw
        }
        if let networkAddresses {
            payload["network_addresses"] = [
                "ipv4": networkAddresses.ipv4.map { $0 as Any } ?? NSNull(),
                "ipv6": networkAddresses.ipv6.map { $0 as Any } ?? NSNull()
            ]
        }
        return payload
    }

    /// A machine created in this process moments ago: the create response already
    /// proved its route and listener, so the CLI needs no attach-endpoint call. The
    /// token is empty exactly as for a known device; the carrier marker is the credential.
    nonisolated static func cmuxRemoteInfoPayload(cachedAttach attach: VMCreateAttach) -> [String: Any] {
        cmuxRemoteInfoPayload(
            route: attach.route, token: "", expiresAtUnix: 0, session: attach.session,
            trustedCarrier: attach.trustedCarrier, daemonBuild: attach.daemonBuild, networkAddresses: nil
        )
    }
}
