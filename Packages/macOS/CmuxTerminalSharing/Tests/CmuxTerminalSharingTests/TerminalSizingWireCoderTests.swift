import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import Testing

@Suite struct TerminalSizingWireCoderTests {
    let coder = TerminalSizingWireCoder()

    @Test func stateRoundTripsThroughDictionaries() {
        let state = TerminalSizingState(
            generation: 7, cols: 118, rows: 38, reason: .latest, owners: ["c3"], policy: .latest,
            participants: [TerminalSizingParticipantState(participant: TerminalSizingParticipant(id: "c3", userID: "u", deviceKind: .mac, viewport: TerminalGridSize(cols: 118, rows: 38)), counts: true)]
        )
        let object = coder.jsonObject(state)
        #expect(object["generation"] as? Int == 7)
        #expect(coder.state(from: object) == state)
    }

    @Test func policyRejectsUnknownModes() {
        #expect(coder.policy(from: ["mode": "bogus"]) == nil)
        #expect(coder.policy(from: ["mode": "fixed", "fixed": ["cols": 1, "rows": 0]])?.fixed == TerminalGridSize(cols: 2, rows: 1))
    }

    @Test func detachedPayloadCarriesReasonByAndISOTime() {
        let payload = coder.detachedPayload(
            surfaceID: "S",
            detachment: TerminalSharingDetachment(reason: .disconnectedBy(TerminalDetachActor(userID: "u", displayName: "Maya", deviceName: "Mac")), at: Date(timeIntervalSince1970: 0))
        )
        #expect(payload["reason"] as? String == "disconnected-by")
        #expect(payload["at"] as? String == "1970-01-01T00:00:00Z")
        #expect((payload["by"] as? [String: Any])?["display_name"] as? String == "Maya")
    }

    @Test func sizeStatePayloadCarriesDetachmentWhileDetached() throws {
        let state = try #require(coder.state(from: [
            "generation": 3, "cols": 80, "rows": 24, "reason": "smallest", "owners": ["m"],
            "policy": ["mode": "smallest", "priority": [], "fixed": NSNull()],
            "participants": [],
        ]))
        let attached = TerminalSharingSnapshot(state: state, selfParticipantID: "m", isCloud: true)
        let live = coder.sizeStatePayload(surfaceID: "S", snapshot: attached)
        #expect(live["detachment"] is NSNull)
        #expect(live["self_participant_id"] as? String == "m")

        var kicked = attached
        kicked.detachment = TerminalSharingDetachment(
            reason: .disconnectedBy(TerminalDetachActor(userID: "u2", displayName: "Maya", deviceName: "Maya's iPhone")),
            at: Date(timeIntervalSince1970: 0)
        )
        let payload = coder.sizeStatePayload(surfaceID: "S", snapshot: kicked)
        let detachment = try #require(payload["detachment"] as? [String: Any])
        #expect(detachment["reason"] as? String == "disconnected-by")
        #expect(detachment["at"] as? String == "1970-01-01T00:00:00Z")
        #expect((detachment["by"] as? [String: Any])?["device_name"] as? String == "Maya's iPhone")
        #expect(detachment["surface_id"] == nil)
        #expect(payload["surface_id"] as? String == "S")

        let unshared = coder.sizeStatePayload(surfaceID: "S", snapshot: nil)
        #expect(unshared["size_state"] is NSNull)
        #expect(unshared["detachment"] is NSNull)
    }
}
