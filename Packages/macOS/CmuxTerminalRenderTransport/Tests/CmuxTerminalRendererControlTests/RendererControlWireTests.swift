import CmuxTerminalRendererControl
import CmuxTerminalRenderProtocol
import Foundation
import Testing

@Suite
struct RendererControlWireTests {
    private let fixture = RendererControlTestFixture()

    @Test
    func bootstrapGoldenFixtureUsesNetworkByteOrder() throws {
        let expected = try fixture.goldenData(named: "renderer-control-v1")
        let bootstrap = try RendererBootstrap(
            daemonInstanceID: try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")),
            workspaceID: try #require(UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")),
            rendererEpoch: 0x0102_0304_0506_0708
        )
        let envelope = try RendererControlEnvelope(
            direction: .daemonToWorker,
            sequence: 1,
            message: .bootstrap(bootstrap)
        )
        let encoded = try RendererControlWire().encode(envelope)
        #expect(encoded == expected)
        #expect(try RendererControlWire().decode(expected) == envelope)
    }

    @Test
    func variablePayloadAndWorkerReplyMatchCrossLanguageGoldens() throws {
        let terminalID = try #require(UUID(uuidString: "11112222-3333-4444-5555-666677778888"))
        let presentationID = try #require(UUID(uuidString: "9999aaaa-bbbb-cccc-dddd-eeeeffff0001"))
        let endpoint = try TerminalRenderFrameEndpoint(
            serviceName: "svc",
            capability: Data((0..<32).map(UInt8.init))
        )
        let attachment = try RendererPresentationAttachment(
            terminalID: terminalID,
            terminalEpoch: 0x1112_1314_1516_1718,
            presentationID: presentationID,
            presentationGeneration: 0x2122_2324_2526_2728,
            width: 1_280,
            height: 800,
            backingScaleFactor: 2,
            pixelFormat: .bgra8Unorm,
            colorSpace: .displayP3,
            frameEndpoint: endpoint,
            resolvedConfigRevision: 0x3132_3334_3536_3738,
            resolvedConfig: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        let upsert = try RendererControlEnvelope(
            direction: .daemonToWorker,
            sequence: 1,
            message: .upsertPresentation(attachment)
        )
        let upsertGolden = try fixture.goldenData(named: "renderer-control-v1-upsert")
        #expect(try RendererControlWire().encode(upsert) == upsertGolden)
        #expect(try RendererControlWire().decode(upsertGolden) == upsert)

        let ready = try RendererControlEnvelope(
            direction: .workerToDaemon,
            sequence: 1,
            message: .ready(RendererWorkerReady(
                processID: 0x0102_0304,
                effectiveUserID: 0x0506_0708,
                sceneCapabilities: [.fullScene, .canonicalDelta, .presentationDelta]
            ))
        )
        let readyGolden = try fixture.goldenData(named: "renderer-control-v1-ready")
        #expect(try RendererControlWire().encode(ready) == readyGolden)
        #expect(try RendererControlWire().decode(readyGolden) == ready)
    }

    @Test
    func everyTypedMessageRoundTrips() throws {
        let messages: [RendererControlMessage] = [
            .bootstrap(try fixture.bootstrap()),
            .upsertPresentation(try fixture.attachment()),
            .removePresentation(try fixture.removal()),
            .semanticScene(try fixture.scene()),
            .frameRelease(try fixture.release()),
            .shutdown,
            .ready(try fixture.ready()),
            .needsFullScene(try fixture.needsFullScene()),
            .fatal(try RendererFatal(code: .resourceExhausted, diagnostic: "bounded")),
            .presentationReady(try fixture.presentationReady()),
            .presentationRemoved(try fixture.presentationRemoved()),
        ]
        for message in messages {
            let envelope = try fixture.envelope(message, sequence: 1)
            #expect(try RendererControlWire().decode(RendererControlWire().encode(envelope)) == envelope)
        }
    }

    @Test
    func presentationReadyUsesFixed104ByteBigEndianPayload() throws {
        let envelope = try fixture.envelope(
            .presentationReady(fixture.presentationReady()),
            sequence: 2
        )
        let encoded = try RendererControlWire().encode(envelope)
        #expect(encoded.count == RendererControlProtocol.headerLength + 104)
        #expect(encoded[8] == RendererControlDirection.workerToDaemon.rawValue)
        #expect(encoded[9] == 0x84)
        #expect(Array(encoded[32..<48]) == Array(fixture.terminalA.uuidBytes))
        #expect(Array(encoded[48..<56]) == [0, 0, 0, 0, 0, 0, 0, 9])
        #expect(Array(encoded[96..<100]) == [0, 0, 0, 120])
        #expect(Array(encoded[100..<104]) == [0, 0, 0, 40])
        #expect(Array(encoded.suffix(8)) == Array(repeating: 0, count: 8))
    }

    @Test
    func presentationRemovedUsesFixed56ByteBigEndianPayload() throws {
        let envelope = try fixture.envelope(
            .presentationRemoved(fixture.presentationRemoved()),
            sequence: 2
        )
        let encoded = try RendererControlWire().encode(envelope)
        #expect(encoded.count == RendererControlProtocol.headerLength + 56)
        #expect(encoded[8] == RendererControlDirection.workerToDaemon.rawValue)
        #expect(encoded[9] == 0x85)
        #expect(Array(encoded[32..<48]) == Array(fixture.terminalA.uuidBytes))
        #expect(Array(encoded[48..<56]) == [0, 0, 0, 0, 0, 0, 0, 9])
        #expect(Array(encoded[56..<72]) == Array(fixture.presentationA.uuidBytes))
        #expect(Array(encoded[72..<80]) == [0, 0, 0, 0, 0, 0, 0, 1])
        #expect(Array(encoded.suffix(8)) == Array(repeating: 0, count: 8))
    }
}

private extension UUID {
    var uuidBytes: [UInt8] {
        var value = uuid
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}
