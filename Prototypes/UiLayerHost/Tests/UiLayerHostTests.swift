import Foundation
import Testing

@testable import UiLayerHost

@Suite struct UiLayerHostProtocolTests {
    @Test func attachIsExplicitAndCannotShareFixtureSource() {
        guard case .attach(let path) = UiLayerSource.parse(arguments: ["host", "--attach", "/tmp/cmux.sock"]) else {
            Issue.record("--attach did not select the live source")
            return
        }
        #expect(path == "/tmp/cmux.sock")
        guard case .invalid = UiLayerSource.parse(arguments: ["host", "--attach", "/tmp/cmux.sock", "--snapshot", "/tmp/state.json"]) else {
            Issue.record("--attach and --snapshot were accepted together")
            return
        }
    }

    @Test func eventCursorRequiresGapFreeBootBoundStream() throws {
        var cursor = try EventCursor(ack: [
            "type": "ack", "protocol": "cmux-events", "version": 1,
            "boot_id": "boot-a", "resume": ["latest_seq": 4, "gap": false],
        ])
        #expect(try cursor.accept(frame: [
            "type": "event", "protocol": "cmux-events", "version": 1,
            "boot_id": "boot-a", "seq": 5,
        ]) == .event)
        #expect(throws: LiveProjectionError.self) {
            _ = try cursor.accept(frame: [
                "type": "event", "protocol": "cmux-events", "version": 1,
                "boot_id": "boot-a", "seq": 7,
            ])
        }
        #expect(throws: LiveProjectionError.self) {
            _ = try EventCursor(ack: [
                "type": "ack", "protocol": "cmux-events", "version": 1,
                "boot_id": "boot-a", "resume": ["latest_seq": 4, "gap": true],
            ])
        }
    }

    @Test func identifyFingerprintAcceptsNullableOptionalIdentityFields() throws {
        let identity = try IdentifyFingerprint(result: [
            "app": "cmux NEXT", "version": "dev", "build": "test",
            "bundle_id": NSNull(), "pid": 7, "socket_path": NSNull(),
            "protocol_version": 1,
            "methods": ["system.identify", "snapshot.get", "events.stream"],
        ])
        #expect(identity.bundleID == nil)
        #expect(identity.socketPath == nil)
        #expect(identity.protocolVersion == 1)
    }
}

@MainActor
@Suite struct UiLayerHostOptionsTests {
    @Test func sizesAnimationAndLookFlagsParse() {
        let options = UiLayerHostOptions.parse(arguments: [
            "host", "--snapshot", "/tmp/s.json", "--sizes", "1470x956,bogus,100x100", "--animate", "--no-app-look",
        ])
        #expect(options.sizes == [CGSize(width: 1_470, height: 956), CGSize(width: 320, height: 240)])
        #expect(options.animate)
        #expect(!options.cycleSizes)
        #expect(!options.followsAppLook)
        #expect(UiLayerHostOptions.parse(arguments: ["host", "--sizes", "all"]).sizes == UiLayerHostOptions.allSizes)
        #expect(UiLayerHostOptions.parse(arguments: ["host"]) == UiLayerHostOptions())
    }
}
