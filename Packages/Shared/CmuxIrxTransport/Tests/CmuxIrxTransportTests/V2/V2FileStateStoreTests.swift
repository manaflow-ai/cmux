import Foundation
import Testing
@testable import CmuxIrxTransport

struct V2FileStateStoreTests {
    @Test func replacesOneFilePerScopeAndIgnoresLegacyState() async throws {
        let files = FileManager()
        let root = files.temporaryDirectory.appendingPathComponent("cmux-v2-state-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let legacy = root.appendingPathComponent("iroh-state.json")
        let oldBytes = Data("{\"legacy\":true}".utf8)
        try oldBytes.write(to: legacy)
        let identity = V2Identity(appNamespace: "com.cmux.test", buildTag: "test", deviceID: "device", environment: "test", projectID: "project", teamID: "team-one", userID: "user")
        let other = V2Identity(appNamespace: "com.cmux.test", buildTag: "test", deviceID: "device", environment: "test", projectID: "project", teamID: "team-two", userID: "user")
        let store = V2FileStateStore(rootDirectory: root, fileManager: FileManager())
        #expect(try await store.load(identity: identity) == nil)
        var state = V2CachedState(identity: identity)
        for index in 0..<10 {
            state.ticket = V2Ticket(expiresAt: 3600, refreshAfter: 3300, token: "ticket-\(index)")
            try await store.save(state)
        }
        #expect(try await store.load(identity: identity)?.ticket?.token == "ticket-9")
        #expect(try await store.load(identity: other) == nil)
        #expect(try Data(contentsOf: legacy) == oldBytes)
        let directory = root.appendingPathComponent("cmux-iroh-v2/state")
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(entries.count == 1)
        let attributes = try files.attributesOfItem(atPath: entries[0].path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
