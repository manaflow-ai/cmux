@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `cloud.place.get`: the kept move view passes through as Rust drew it, null with none, and a session is required.
@MainActor @Suite struct CloudPlaceControlTests {
    @Test func theKeptViewPassesThroughWithItsSteps() throws {
        let view: [String: Any] = ["state": "live", "elapsedMs": 4200, "steps": [["step": "machine", "ms": 300], ["step": "sync", "ms": 1900]]]
        let reply = try CloudPlaceControl.reply(["session": .string("s")]) { $0 == "s" ? view : nil }
        #expect(reply["session"]?.stringValue == "s")
        #expect(reply["move"]?["state"]?.stringValue == "live")
        #expect(reply["move"]?["steps"]?.arrayValue?.count == 2)
        #expect(try CloudPlaceControl.reply(["session": .string("other")]) { $0 == "s" ? view : nil }["move"]?.isNull == true)
    }

    @Test func aSessionIsRequired() {
        #expect(throws: (any Error).self) { try CloudPlaceControl.reply([:]) { _ in nil } }
        #expect(throws: (any Error).self) { try CloudPlaceControl.reply(["session": .string("")]) { _ in nil } }
    }
}
