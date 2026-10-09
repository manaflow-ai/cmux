import CmuxMobileHost
import CmuxMobileWire

/// The current `HostDO` host socket and its uplink, replaced on every
/// reconnect, so the WebRTC signaling channel and the TURN reads (made once)
/// always use the live socket.
actor HostSocketBox {
    private var socket: ControlPlaneHostSocket?
    private var uplink: HostControlUplink?

    func set(_ socket: ControlPlaneHostSocket?, uplink: HostControlUplink? = nil) {
        self.socket = socket
        self.uplink = socket == nil ? nil : uplink
    }

    func send(_ frame: JSONValue) async throws {
        guard let socket else { throw HostControlUplinkError(code: "owner.unreachable", message: "no host socket") }
        try await socket.send(frame)
    }

    /// One read as the host role (`signal.turn_credentials`).
    func read(_ op: String, params: JSONValue) async throws -> ReadResultFrame {
        guard let uplink else { throw HostControlUplinkError(code: "owner.unreachable", message: "no host socket") }
        return try await uplink.read(op, params: params)
    }

    func close() async {
        await socket?.close()
        socket = nil
        uplink = nil
    }
}
