import CmuxControlPlane
import CmuxMobileHost
import Foundation
import Testing

private actor ScriptedControlPlaneConnection: ControlPlaneConnection {
    private let continuation: AsyncStream<String>.Continuation
    private var iterator: AsyncStream<String>.Iterator
    private(set) var closeCode: Int?

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()
    }

    func push(_ text: String) {
        continuation.yield(text)
    }

    func send(_ text: String) async throws {}

    func receive() async throws -> String {
        guard let text = await iterator.next() else { throw CancellationError() }
        return text
    }

    func close(code: Int) async {
        closeCode = code
        continuation.finish()
    }
}

@Suite("Host socket ingress")
struct ControlPlaneHostSocketTests {
    @Test("overflow closes the socket instead of dropping control frames")
    func overflowClosesConnection() async throws {
        let connection = ScriptedControlPlaneConnection()
        let socket = ControlPlaneHostSocket(connection: connection)
        _ = socket.frames
        for sequence in 0...256 {
            await connection.push("{\"t\":\"event\",\"seq\":\(sequence)}")
        }

        let code = try await within {
            while await connection.closeCode == nil { await Task.yield() }
            return await connection.closeCode
        }
        #expect(code == 1013)
    }
}
