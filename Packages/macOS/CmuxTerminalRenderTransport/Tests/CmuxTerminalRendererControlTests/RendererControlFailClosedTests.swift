import CmuxTerminalRendererControl
import Foundation
import Testing

@Suite
struct RendererControlFailClosedTests {
    private let fixture = RendererControlTestFixture()

    @Test(arguments: [
        (4, UInt8(2)),
        (9, UInt8(0x7F)),
        (10, UInt8(1)),
        (12, UInt8(1)),
    ])
    func unknownHeaderFieldsAreRejected(offset: Int, replacement: UInt8) throws {
        var encoder = RendererControlEncoder(direction: .daemonToWorker)
        var frame = try encoder.encode(.bootstrap(fixture.bootstrap()))
        frame[offset] = replacement
        #expect(throws: RendererControlError.self) {
            try RendererControlWire().decode(frame)
        }
    }

    @Test
    func nonzeroPayloadReservedFieldIsRejected() throws {
        var encoder = RendererControlEncoder(direction: .daemonToWorker)
        var frame = try encoder.encode(.bootstrap(fixture.bootstrap()))
        frame[frame.count - 1] = 1
        #expect(throws: RendererControlError.nonzeroReserved) {
            try RendererControlWire().decode(frame)
        }
    }

    @Test
    func unknownCapabilitiesAndReasonsAreRejected() throws {
        var workerEncoder = RendererControlEncoder(direction: .workerToDaemon)
        var ready = try workerEncoder.encode(.ready(fixture.ready()))
        ready[47] = 0x83
        #expect(throws: RendererControlError.unknownSceneCapabilities(0x83)) {
            try RendererControlWire().decode(ready)
        }

        var reason = try RendererControlWire().encode(fixture.envelope(
            .needsFullScene(try fixture.needsFullScene()),
            sequence: 1
        ))
        reason[99] = 0x7F
        #expect(throws: RendererControlError.unknownNeedsFullSceneReason(0x7F)) {
            try RendererControlWire().decode(reason)
        }
    }

    @Test
    func messageTypeFromTheWrongDirectionIsRejected() throws {
        var encoder = RendererControlEncoder(direction: .daemonToWorker)
        var frame = try encoder.encode(.bootstrap(fixture.bootstrap()))
        frame[8] = RendererControlDirection.workerToDaemon.rawValue
        #expect(throws: RendererControlError.unknownMessageType(1)) {
            try RendererControlWire().decode(frame)
        }
    }
}
