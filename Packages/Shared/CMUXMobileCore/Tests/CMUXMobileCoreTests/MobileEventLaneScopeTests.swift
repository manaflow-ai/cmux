import Foundation
import Testing
@testable import CMUXMobileCore

@Suite("Mobile event lane scope")
struct MobileEventLaneScopeTests {
    private func envelopes(_ data: Data) throws -> [[String: Any]] {
        var buffer = data
        return try MobileSyncFrameCodec.decodeFrames(from: &buffer).map {
            try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
    }

    @Test func scopedFramesOpenAndCloseAroundTheLanesFrames() throws {
        let event = try MobileSyncFrameCodec.encodeFrame(Data(#"{"kind":"event","topic":"t"}"#.utf8))
        let decoded = try envelopes(MobileEventLaneScope.scoped(event, surfaceID: "abc"))
        #expect(decoded.count == 3)
        #expect(MobileEventLaneScope.scopeChange(in: decoded[0]) == .some("abc"))
        #expect(MobileEventLaneScope.scopeChange(in: decoded[1]) == nil)
        #expect(MobileEventLaneScope.scopeChange(in: decoded[2]) == .some(nil))
    }

    @Test func anEventBelongsOnlyToTheLaneOfTheTerminalItNames() {
        let id = UUID().uuidString
        #expect(MobileEventLaneScope.eventBelongs(payload: ["surface_id": id], toScope: id.lowercased()))
        #expect(!MobileEventLaneScope.eventBelongs(payload: ["surface_id": UUID().uuidString], toScope: id))
        #expect(!MobileEventLaneScope.eventBelongs(payload: ["workspace_id": id], toScope: id))
        #expect(!MobileEventLaneScope.eventBelongs(payload: nil, toScope: id))
    }
}
