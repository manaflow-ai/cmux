import CmuxMobileModel
import CmuxMobileTransport
import Foundation

/// The Mac's terminal sizing policy over one `daemon` channel
/// (cmux-next-ios/PROTOCOL.md "Terminal sizing policy"): one policy per Mac,
/// stored and applied by its cmux-tui daemon. The phone sends its preference
/// with `set-host-size-policy`; `get-host-size-policy {surface}` also names
/// the participants of that terminal that are the Mac's own views.
public struct HostSizePolicyChannel: Sendable {
    let client: DaemonClient

    public init(client: DaemonClient) {
        self.client = client
    }

    public func get(surface: Int? = nil) async throws -> HostSizePolicyInfo {
        let reply = try await client.request("get-host-size-policy", params: surface.map { ["surface": $0] } ?? [:],
                                             deadline: .seconds(10))
        guard let info = HostSizePolicyInfo.decode(try Self.data(reply, "get-host-size-policy")) else {
            throw LinkError(code: "bad_reply", message: "get-host-size-policy: no policy in the reply")
        }
        return info
    }

    public func set(_ policy: HostSizePolicy) async throws -> HostSizePolicy {
        let reply = try await client.request("set-host-size-policy", params: ["policy": policy.wire], deadline: .seconds(10))
        guard let stored = HostSizePolicy.decode((try Self.data(reply, "set-host-size-policy") as? [String: Any])?["policy"]) else {
            throw LinkError(code: "bad_reply", message: "set-host-size-policy: no policy in the reply")
        }
        return stored
    }

    private static func data(_ reply: Data, _ cmd: String) throws -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw LinkError(code: "bad_reply", message: "\(cmd): bad reply")
        }
        if object["ok"] as? Bool == false || object["error"] != nil {
            let error = object["error"] as? String ?? "refused"
            // An older Mac: say what to do instead of a raw protocol error.
            if error.contains("unknown command") || error.contains("not available to a phone") {
                throw HostSizePolicyError(message: "This Mac's cmux is too old to change the terminal size setting from the phone.")
            }
            throw HostSizePolicyError.refused(error)
        }
        return object["data"]
    }
}

#if os(iOS)
extension LiveCoordinator: TerminalSizingService {
    public var thisDeviceID: String? { identity.link }

    /// A short-lived `daemon` channel on the Mac's link for one policy call.
    private func hostPolicyChannel(_ macID: String) async throws -> (HostSizePolicyChannel, DaemonClient) {
        // A Mac with no link opens one; the page tries again when asked.
        touch(macID)
        guard let owner = sessions[macID] else { throw LinkError(code: "no-link", message: "Not connected to this Mac yet.") }
        let link = try await pairedLink(owner)
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        await client.start()
        return (HostSizePolicyChannel(client: client), client)
    }

    public func hostPolicy(macID: String, surface: Int?) async throws -> HostSizePolicyInfo {
        let (channel, client) = try await hostPolicyChannel(macID)
        defer { Task { await client.close() } }
        return try await channel.get(surface: surface)
    }

    public func setHostPolicy(macID: String, policy: HostSizePolicy) async throws -> HostSizePolicy {
        let (channel, client) = try await hostPolicyChannel(macID)
        defer { Task { await client.close() } }
        return try await channel.set(policy)
    }
}
#endif
