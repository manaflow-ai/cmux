import CmuxTerminalSizing
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileTerminalSizingEventsTests {
    /// The wire object from `docs/shared-terminal-sizing.md`.
    private let stateJSON = """
    {"generation":7,"cols":118,"rows":38,"reason":"latest","owners":["c3"],
     "policy":{"mode":"latest","priority":[],"fixed":null},
     "participants":[{"id":"c3","user_id":"u_maya","display_name":"Maya Ortiz",
       "device_kind":"mac","device_name":"Mac Studio","via":null,
       "viewport":{"cols":118,"rows":38},"counts_override":null,
       "counts":true,"priority_key":"u_maya/mac"}]}
    """

    @Test func decodesSizeStatePush() throws {
        let json = #"{"surface_id":"s1","self_participant_id":"mobile:abc","state":"# + stateJSON + "}"
        let event = try MobileTerminalSizeStateEvent.decode(Data(json.utf8))
        #expect(event.surfaceID == "s1")
        #expect(event.selfParticipantID == "mobile:abc")
        #expect(event.state.generation == 7)
        #expect(event.state.size == TerminalGridSize(cols: 118, rows: 38))
        #expect(event.state.soleOwner?.participant.displayName == "Maya Ortiz")
        #expect(event.state.participants.first?.participant.deviceKind == .mac)
    }

    @Test func decodesDisconnectedByDetach() throws {
        let json = """
        {"surface_id":"s1","reason":"disconnected-by",
         "by":{"user_id":"u_maya","display_name":"Maya Ortiz","device_name":"Mac Studio"},
         "at":"2026-09-27T14:05:00.250Z"}
        """
        let event = try MobileTerminalDetachedEvent.decode(Data(json.utf8))
        #expect(event.surfaceID == "s1")
        #expect(event.reason == .disconnectedBy(TerminalDetachActor(
            userID: "u_maya", displayName: "Maya Ortiz", deviceName: "Mac Studio"
        )))
        #expect(!event.reason.reconnectsAutomatically)
        let at = try #require(event.at)
        #expect(abs(at.timeIntervalSince1970 - 1_790_517_900.25) < 0.001)
    }

    @Test func decodesNetworkDetachAndPlainTimestamp() throws {
        let json = #"{"surface_id":"s1","reason":"network","by":null,"at":"2026-09-27T14:05:00Z"}"#
        let event = try MobileTerminalDetachedEvent.decode(Data(json.utf8))
        #expect(event.reason == .network)
        #expect(event.reason.reconnectsAutomatically)
        #expect(event.at != nil)
    }

    @Test func unknownDetachReasonKeepsReconnecting() throws {
        let json = #"{"surface_id":"s1","reason":"future-reason"}"#
        let event = try MobileTerminalDetachedEvent.decode(Data(json.utf8))
        #expect(event.reason == .network)
        #expect(event.at == nil)
    }

    @Test func replayResponseCarriesSizing() throws {
        let json = #"{"seq":3,"self_participant_id":"mobile:abc","size_state":"# + stateJSON + "}"
        let response = try MobileTerminalReplayResponse.decode(Data(json.utf8))
        #expect(response.sequence == 3)
        #expect(response.sizeState?.generation == 7)
        #expect(response.selfParticipantID == "mobile:abc")
        let sizing = try #require(MobileTerminalReplaySizing.decodeIfPresent(Data(json.utf8)))
        #expect(sizing.sizeState?.cols == 118)
    }

    @Test func malformedSizeStateNeverFailsTheReplay() throws {
        let json = #"{"seq":3,"size_state":{"generation":"bad"}}"#
        let response = try MobileTerminalReplayResponse.decode(Data(json.utf8))
        #expect(response.sequence == 3)
        #expect(response.sizeState == nil)
        #expect(MobileTerminalReplaySizing.decodeIfPresent(Data(json.utf8)) == nil)
    }

    @Test func legacyReplayHasNoSizing() throws {
        let response = try MobileTerminalReplayResponse.decode(Data(#"{"seq":1}"#.utf8))
        #expect(response.sizeState == nil)
        #expect(response.selfParticipantID == nil)
    }
}
