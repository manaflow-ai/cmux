import CmuxCloudMachines
import Foundation
import Testing

struct CloudTuiDeviceStoreTests {
    @Test func separateClientsShareIdentityAndAdvertisedRoute() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = CloudTuiDeviceStore(home: home, now: { Date(timeIntervalSince1970: 123) })
        let cli = CloudTuiDeviceStore(home: home, now: { Date(timeIntervalSince1970: 456) })
        let route = "ws://10.0.0.7:8123/custom/link?version=2"
        app.saveAttachState(deviceFingerprint: "carrier", route: route, for: "first")
        #expect(cli.loadDevices()["first"]?.route == route)
        cli.saveAttachState(deviceFingerprint: "enrolled-key", for: "first")
        app.saveAttachState(deviceFingerprint: "second-key", for: "second")
        let restored = CloudTuiDeviceStore(home: home).loadDevices()
        #expect(restored["first"]?.deviceFingerprint == "enrolled-key")
        #expect(restored["first"]?.route == route)
        #expect(restored["first"]?.updatedAtUnix == 456)
        #expect(restored["second"]?.deviceFingerprint == "second-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: app.devicesStoreURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func legacyRecordsGainRouteWithoutChangingIdentity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = CloudTuiDeviceStore(home: home)
        try FileManager.default.createDirectory(at: store.devicesStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"old":{"deviceFingerprint":"legacy-key","updatedAtUnix":1}}"#.utf8)
            .write(to: store.devicesStoreURL)
        #expect(store.loadDevices()["old"]?.route == nil)
        store.saveAttachState(route: "ws://[fd00::7]:8123/link", for: "old")
        let record = try #require(store.loadDevices()["old"])
        #expect(record.deviceFingerprint == "legacy-key")
        #expect(record.route == "ws://[fd00::7]:8123/link")
    }

    @Test func routeAloneDoesNotCreateTrustedRecord() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = CloudTuiDeviceStore(home: home)
        store.saveAttachState(route: "ws://10.0.0.7:8123/link", for: "unknown")
        #expect(store.loadDevices().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.devicesStoreURL.path))
    }
}
