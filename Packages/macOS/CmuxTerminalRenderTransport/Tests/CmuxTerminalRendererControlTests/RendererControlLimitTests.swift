import CmuxTerminalRendererControl
import Foundation
import Testing

@Suite
struct RendererControlLimitTests {
    private let fixture = RendererControlTestFixture()

    @Test
    func semanticSceneAcceptsExactly64MiBAndRejectsOneByteMore() throws {
        let maximum = Data(
            repeating: 0xA5,
            count: RendererControlProtocol.maximumSemanticSceneLength
        )
        let message = RendererControlMessage.semanticScene(try fixture.scene(bytes: maximum))
        let envelope = try fixture.envelope(message, sequence: 1)
        let encoded = try RendererControlWire().encode(envelope)
        #expect(encoded.count == RendererControlProtocol.maximumFrameLength)
        #expect(try RendererControlWire().decode(encoded) == envelope)

        let oneOver = Data(
            repeating: 0,
            count: RendererControlProtocol.maximumSemanticSceneLength + 1
        )
        #expect(throws: RendererControlError.semanticSceneTooLarge) {
            try fixture.scene(bytes: oneOver)
        }
    }

    @Test
    func resolvedConfigAccepts256KiBAndRejectsOneByteMore() throws {
        let maximum = Data(
            repeating: 0x5C,
            count: RendererControlProtocol.maximumResolvedConfigLength
        )
        let attachment = try fixture.attachment(config: maximum)
        let envelope = try fixture.envelope(.upsertPresentation(attachment), sequence: 1)
        #expect(try RendererControlWire().decode(RendererControlWire().encode(envelope)) == envelope)

        let oneOver = Data(
            repeating: 0,
            count: RendererControlProtocol.maximumResolvedConfigLength + 1
        )
        #expect(throws: RendererControlError.resolvedConfigTooLarge) {
            try fixture.attachment(config: oneOver)
        }
    }

    @Test
    func diagnosticAccepts4KiBAndRejectsOneByteMore() throws {
        let maximum = String(
            repeating: "x",
            count: RendererControlProtocol.maximumDiagnosticLength
        )
        let fatal = try RendererFatal(code: .renderFailure, diagnostic: maximum)
        let envelope = try fixture.envelope(.fatal(fatal), sequence: 1)
        #expect(try RendererControlWire().decode(RendererControlWire().encode(envelope)) == envelope)

        let oneOver = String(
            repeating: "y",
            count: RendererControlProtocol.maximumDiagnosticLength + 1
        )
        #expect(throws: RendererControlError.diagnosticTooLarge) {
            try RendererFatal(code: .renderFailure, diagnostic: oneOver)
        }
    }
}
