import CmuxControlPlane
import CmuxMobileWire
import Foundation

/// The server end of one fake socket.
final class FakeServerSocket: Sendable {
    let clientSide: FakeClientConnection
    private let toServer = FrameQueue()
    private let toClient = FrameQueue()

    init() {
        clientSide = FakeClientConnection(toServer: toServer, toClient: toClient)
    }

    /// The next frame the client sent, decoded.
    func next() async throws -> MobileFrame {
        try MobileFrame(decoding: Data(try await toServer.pop().utf8))
    }

    /// The next frame of type `t`, skipping others.
    func next(_ type: MobileFrameType) async throws -> MobileFrame {
        while true {
            let f = try await next()
            if f.type == type { return f }
        }
    }

    func send(_ frame: MobileFrame) throws {
        toClient.push(String(decoding: try frame.encoded(), as: UTF8.self))
    }

    func sendRaw(_ json: String) {
        toClient.push(json)
    }

    /// Answers the client's hello with version 1 and the common caps.
    func acceptHello(caps: [String] = ["read", "signal", "presence", "resume"]) async throws -> HelloFrame {
        guard case .hello(let hello) = try await next(.hello) else { throw ControlPlaneCloseError(code: 1002) }
        try send(.helloOK(HelloOKFrame(version: 1, caps: caps.filter(hello.caps.contains), serverTime: 1, maxFrame: 131072)))
        return hello
    }

    func close(code: Int, reason: String = "") {
        toClient.finish(ControlPlaneCloseError(code: code, reason: reason))
    }
}
