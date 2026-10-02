import Darwin
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Web Inspector plist framing")
struct SimulatorWebInspectorPlistTests {
    private let frameCodec = SimulatorWebInspectorPlistFrameCodec()

    @Test("XML frames use a four-byte big-endian body length")
    func xmlFrame() throws {
        let frame = try frameCodec.frame([
            "__selector": "_rpc_reportIdentifier:",
            "__argument": ["WIRConnectionIdentifierKey": "CONNECTION"],
        ])
        let bodyLength = try frameCodec.bodyLength(
            header: frame.prefix(4)
        )
        #expect(bodyLength == frame.count - 4)
        let decoded = try frameCodec.decodeBody(frame.dropFirst(4))
        #expect(decoded["__selector"] as? String == "_rpc_reportIdentifier:")
    }

    @Test("Foundation decodes binary Web Inspector property lists")
    func binaryBody() throws {
        let body = try PropertyListSerialization.data(
            fromPropertyList: ["WIRTitleKey": "Fixture"],
            format: .binary,
            options: 0
        )
        let decoded = try frameCodec.decodeBody(body)
        #expect(decoded["WIRTitleKey"] as? String == "Fixture")
    }

    @Test("Socket buffering has an explicit aggregate byte ceiling")
    func socketQueueCap() {
        #expect(SimulatorWebInspectorSocket.maximumBufferedBodyCount == 1)
        #expect(
            SimulatorWebInspectorSocket.maximumBufferedBodyBytes
                == frameCodec.maximumBodyLength
        )
        #expect(SimulatorWebInspectorSocket.maximumBufferedBodyBytes <= 64 * 1024 * 1024)
        #expect(SimulatorWebInspectorSocket.maximumPendingWriteBytes == 4 * 1024 * 1024)
    }

    @Test("Large frames survive partial nonblocking socket writes")
    @MainActor
    func partialSocketWrites() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { Darwin.close(descriptors[1]) }
        var sendBufferBytes: Int32 = 1_024
        try #require(withUnsafePointer(to: &sendBufferBytes) { pointer in
            setsockopt(
                descriptors[0], SOL_SOCKET, SO_SNDBUF,
                pointer, socklen_t(MemoryLayout<Int32>.size)
            )
        } == 0)

        let propertyList: [String: Any] = [
            "__selector": "_rpc_forwardSocketData:",
            "__argument": ["WIRSocketDataKey": Data(repeating: 0x5a, count: 512 * 1_024)],
        ]
        let expected = try frameCodec.frame(propertyList)
        let peer = descriptors[1]
        let reader = Task.detached { () -> Data in
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while received.count < expected.count {
                let requested = min(buffer.count, expected.count - received.count)
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(peer, raw.baseAddress, requested)
                }
                guard count > 0 else { break }
                received.append(contentsOf: buffer.prefix(count))
                usleep(1_000)
            }
            return received
        }
        let socket = SimulatorWebInspectorSocket(
            descriptor: descriptors[0],
            frameCodec: frameCodec
        )
        try socket.send(propertyList: propertyList)
        let received = await reader.value
        #expect(received == expected)
        socket.close()
    }

    @Test("Only the selected Simulator's launchd socket shape is accepted")
    func socketDiscoveryParsing() {
        let output = """
        inherited environment = {
            RWI_LISTEN_SOCKET => /private/var/tmp/com.apple.launchd.ABC/com.apple.webinspectord_sim.socket
        }
        """
        #expect(
            SimulatorWebInspectorSocketDiscovery(
                subprocessRunner: SimulatorSubprocessRunner()
            ).parseSocketPath(output)
                == "/private/var/tmp/com.apple.launchd.ABC/com.apple.webinspectord_sim.socket"
        )
        #expect(SimulatorWebInspectorSocketDiscovery(
            subprocessRunner: SimulatorSubprocessRunner()
        ).parseSocketPath(
            "RWI_LISTEN_SOCKET => /tmp/untrusted.socket"
        ) == nil)
    }
}
