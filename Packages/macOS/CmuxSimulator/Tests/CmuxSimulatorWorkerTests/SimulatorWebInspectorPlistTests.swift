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
