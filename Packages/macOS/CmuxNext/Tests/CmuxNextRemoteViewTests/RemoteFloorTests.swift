import Foundation
@testable import CmuxNextRemoteView
import Testing

/// The host's `floor` message (several viewers, one in control at a time), as cmux-rd-proto's
/// golden vectors write it (tests/vectors/control.json, `floor_view_only` and `floor_control`).
@Suite struct RemoteFloorTests {
    @Test func theFloorVectorsParseAndEncodeBack() throws {
        let viewOnly = try RemoteRdControl.parse(Data(#"{"t": "floor", "control": false, "holder": "Ann's Mac"}"#.utf8))
        #expect(viewOnly == .floor(RemoteFloor(control: false, holder: "Ann's Mac")))
        let control = try RemoteRdControl.parse(Data(#"{"t": "floor", "control": true}"#.utf8))
        #expect(control == .floor(RemoteFloor(control: true)))
        for message in [viewOnly, control] {
            #expect(try RemoteRdControl.parse(try message.json()) == message)
        }
        // A request names no holder.
        let ask = try JSONSerialization.jsonObject(with: try RemoteRdControl.floor(RemoteFloor(control: true)).json()) as? [String: Any]
        #expect(ask?["t"] as? String == "floor")
        #expect(ask?["holder"] == nil)
    }

    @Test func aStatusWithoutAFloorIsOneViewerAtATime() {
        #expect(RemoteViewStatus(state: .connecting).floor == nil)
    }
}
