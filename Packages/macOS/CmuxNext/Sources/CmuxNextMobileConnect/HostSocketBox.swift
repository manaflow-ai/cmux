import CmuxMobileHost
import CmuxMobileWire

/// The current `HostDO` host socket, replaced on every reconnect, so the
/// WebRTC signaling channel (made once) always writes to the live socket.
actor HostSocketBox {
    private var socket: ControlPlaneHostSocket?

    func set(_ socket: ControlPlaneHostSocket?) {
        self.socket = socket
    }

    func send(_ frame: JSONValue) async throws {
        guard let socket else { throw HostControlUplinkError(code: "owner.unreachable", message: "no host socket") }
        try await socket.send(frame)
    }

    func close() async {
        await socket?.close()
        socket = nil
    }
}
