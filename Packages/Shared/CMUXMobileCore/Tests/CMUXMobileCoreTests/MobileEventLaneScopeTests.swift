import Foundation
import Testing
@testable import CMUXMobileCore

@Suite("Mobile event lane scope")
struct MobileEventLaneScopeTests {
    private let scope = MobileEventLaneScope()
    private let surface = UUID()

    private func frames(_ data: Data) throws -> [Data] {
        var buffer = data
        return try MobileSyncFrameCodec.decodeFrames(from: &buffer)
    }

    @Test func everyForwardedFrameGetsItsOwnMarker() throws {
        let first = try MobileSyncFrameCodec.encodeFrame(Data(#"{"kind":"event","topic":"a"}"#.utf8))
        let second = try MobileSyncFrameCodec.encodeFrame(Data(#"{"kind":"event","topic":"b"}"#.utf8))
        let decoded = try frames(scope.scoped(first + second, surfaceID: surface.uuidString.lowercased()))
        #expect(decoded.count == 4)
        #expect(scope.markerScope(inPayload: decoded[0]) == surface)
        #expect(scope.markerScope(inPayload: decoded[1]) == nil)
        #expect(scope.markerScope(inPayload: decoded[2]) == surface)
        #expect(scope.markerScope(inPayload: decoded[3]) == nil)
    }

    @Test func aJSONFrameCanNeverBeAMarker() throws {
        let event = Data(#"{"kind":"lane","surface_id":"anything"}"#.utf8)
        #expect(scope.markerScope(inPayload: event) == nil)
        // A 17-byte JSON frame is still not a marker: it cannot start with 0.
        #expect(scope.markerScope(inPayload: Data(#"{"kind":"lane#x"}"#.utf8)) == nil)
    }

    @Test func aLaneWithoutATerminalUUIDForwardsUnscoped() throws {
        let event = try MobileSyncFrameCodec.encodeFrame(Data(#"{"kind":"event"}"#.utf8))
        #expect(scope.scoped(event, surfaceID: "not-a-terminal") == event)
    }

    @Test func anEventBelongsOnlyToTheLaneOfTheTerminalItNames() {
        #expect(scope.eventBelongs(payload: ["surface_id": surface.uuidString.lowercased()], toScope: surface))
        #expect(!scope.eventBelongs(payload: ["surface_id": UUID().uuidString], toScope: surface))
        #expect(!scope.eventBelongs(payload: ["workspace_id": surface.uuidString], toScope: surface))
        #expect(!scope.eventBelongs(payload: nil, toScope: surface))
    }
}
