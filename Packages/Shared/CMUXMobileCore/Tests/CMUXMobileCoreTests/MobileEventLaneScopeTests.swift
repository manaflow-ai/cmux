import Foundation
import Testing
@testable import CMUXMobileCore

@Suite("Mobile event lane scope")
struct MobileEventLaneScopeTests {
    private let scope = MobileEventLaneScope()

    private func envelopes(_ data: Data) throws -> [[String: Any]] {
        var buffer = data
        return try MobileSyncFrameCodec.decodeFrames(from: &buffer).map {
            try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
    }

    @Test func scopedFramesOpenAndCloseAroundTheLanesFrames() throws {
        let event = try MobileSyncFrameCodec.encodeFrame(Data(#"{"kind":"event","topic":"t"}"#.utf8))
        let decoded = try envelopes(scope.scoped(event, surfaceID: "abc"))
        #expect(decoded.count == 3)
        #expect(scope.scopeChange(in: decoded[0]) == .some("abc"))
        #expect(scope.scopeChange(in: decoded[1]) == nil)
        #expect(scope.scopeChange(in: decoded[2]) == .some(nil))
    }

    @Test func anEventBelongsOnlyToTheLaneOfTheTerminalItNames() {
        let id = UUID().uuidString
        #expect(scope.eventBelongs(payload: ["surface_id": id], toScope: id.lowercased()))
        #expect(!scope.eventBelongs(payload: ["surface_id": UUID().uuidString], toScope: id))
        #expect(!scope.eventBelongs(payload: ["workspace_id": id], toScope: id))
        #expect(!scope.eventBelongs(payload: nil, toScope: id))
    }
}
