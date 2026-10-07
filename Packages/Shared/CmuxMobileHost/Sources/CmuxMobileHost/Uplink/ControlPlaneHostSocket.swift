import CmuxControlPlane
import CmuxMobileWire
import Foundation

/// `HostControlSocket` over B1's `ControlPlaneConnection` (production:
/// `URLSessionControlPlaneTransport` to `/v1/wire/host/<host>` with
/// subprotocols `cmux.wire.v1, bearer.<install token>`).
public final class ControlPlaneHostSocket: HostControlSocket {
    public let frames: AsyncStream<JSONValue>
    private let connection: any ControlPlaneConnection
    private let reader: Task<Void, Never>

    public init(connection: any ControlPlaneConnection) {
        self.connection = connection
        let (frames, continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.frames = frames
        reader = Task {
            // Ends when the socket closes (receive throws).
            while let text = try? await connection.receive() {
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value.objectValue != nil else {
                    continue
                }
                continuation.yield(value)
            }
            continuation.finish()
        }
    }

    /// Connects as the host role.
    public static func connect(transport: any ControlPlaneTransport, baseURL: URL, hostID: String, token: String)
        async throws -> ControlPlaneHostSocket {
        let url = baseURL.appendingPathComponent("v1/wire/host/\(hostID)")
        let connection = try await transport.connect(url: url, protocols: ["cmux.wire.v1", "bearer.\(token)"])
        return ControlPlaneHostSocket(connection: connection)
    }

    public func send(_ frame: JSONValue) async throws {
        try await connection.send(String(decoding: try frame.canonicalData(), as: UTF8.self))
    }

    public func close() async {
        reader.cancel()
        await connection.close(code: 1000)
    }
}
