import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileTerminalReplayResponseSurfaceTests {
    private func response(_ object: [String: Any]) throws -> MobileTerminalReplayResponse {
        try JSONDecoder().decode(
            MobileTerminalReplayResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    @Test func aReplayOfAnotherTerminalIsRecognizedEvenWithoutARenderGrid() throws {
        let requested = UUID().uuidString
        let foreign = try response(["surface_id": UUID().uuidString, "data_b64": "Zm9v", "seq": 3])
        #expect(foreign.namesAnotherTerminal(than: requested))
        let own = try response(["surface_id": requested.lowercased(), "data_b64": "Zm9v", "seq": 3])
        #expect(!own.namesAnotherTerminal(than: requested))
    }

    @Test func anOlderHostThatOmitsTheTerminalIsNotRefused() throws {
        #expect(try !response(["data_b64": "Zm9v"]).namesAnotherTerminal(than: UUID().uuidString))
    }
}
