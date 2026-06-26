import Foundation
import Testing
@testable import CmuxTerminal

@Suite struct TerminalSurfaceSocketInputControlSequenceTests {
    @Test func csiDeviceStatusReportQueryRoutesThroughTerminalParser() throws {
        let sequence = "\u{1B}[6n"
        let payload = try #require(singleTerminalBytePayload(for: sequence))

        #expect(payload == Data(sequence.utf8))
    }

    @Test func csiCursorPositionReportRoutesThroughTerminalParser() throws {
        let sequence = "\u{1B}[50;36R"
        let payload = try #require(singleTerminalBytePayload(for: sequence))

        #expect(payload == Data(sequence.utf8))
    }

    private func singleTerminalBytePayload(for text: String) -> Data? {
        let events = TerminalSurface.parsedSocketInputEvents(for: text)
        guard events.count == 1 else { return nil }
        guard case .terminalBytes(let payload) = events[0] else { return nil }
        return payload
    }
}
