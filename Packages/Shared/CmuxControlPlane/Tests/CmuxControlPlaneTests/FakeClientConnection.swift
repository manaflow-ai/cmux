import CmuxControlPlane

/// The client end of a fake socket.
final class FakeClientConnection: ControlPlaneConnection {
    private let toServer: FrameQueue
    private let toClient: FrameQueue

    init(toServer: FrameQueue, toClient: FrameQueue) {
        self.toServer = toServer
        self.toClient = toClient
    }

    func send(_ text: String) async throws {
        toServer.push(text)
    }

    func receive() async throws -> String {
        try await toClient.pop()
    }

    func close(code: Int) async {
        toServer.finish(ControlPlaneCloseError(code: code))
        toClient.finish(ControlPlaneCloseError(code: code))
    }
}
