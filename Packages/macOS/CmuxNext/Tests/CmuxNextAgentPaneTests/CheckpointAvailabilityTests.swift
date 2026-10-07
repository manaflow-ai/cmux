import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor @Suite struct CheckpointAvailabilityTests {
    @Test func availabilityIsAMirrorThatResetsAtEachHandshake() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var changes: [Bool] = []
        model.onCheckpointAvailability = { changes.append($0) }
        #expect(!model.checkpointAvailable)
        let available = AgentPaneRequest(body: ["method": "pane.checkpointAvailability", "params": ["available": true]] as [String: Any])
        _ = await model.respond(to: available)
        _ = await model.respond(to: available)
        #expect(model.checkpointAvailable)
        #expect(changes == [true])
        _ = await model.respond(to: .reconnect)
        #expect(!model.checkpointAvailable)
        #expect(changes == [true, false])
        _ = await model.respond(to: available)
        _ = await model.respond(to: .ready)
        #expect(!model.checkpointAvailable)
        #expect(changes == [true, false, true, false])
    }
    @Test func anInvalidAvailabilityMessageCannotEnableCapture() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let invalid = AgentPaneRequest(body: ["method": "pane.checkpointAvailability", "params": ["available": "true"]] as [String: Any])
        let reply = await model.respond(to: invalid)
        #expect(reply["ok"] as? Bool == false)
        #expect(!model.checkpointAvailable)
    }
}
