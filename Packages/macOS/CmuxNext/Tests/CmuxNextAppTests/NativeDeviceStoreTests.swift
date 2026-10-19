import CryptoKit
import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct NativeDeviceStoreTests {
    @Test(arguments: ["account", "team", "mesh", "origin", "install"])
    func independentNamespacesNeverShareAWireGuardKey(dimension: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = NativeDeviceStore(root: root, namespace: "one"), second = NativeDeviceStore(root: root, namespace: "one/\(dimension)/two")
        let key = try first.loadOrCreate().key.publicKey.rawRepresentation
        #expect(try second.loadOrCreate().key.publicKey.rawRepresentation != key)
        #expect(try first.loadOrCreate().key.publicKey.rawRepresentation == key)
    }

    @Test func aDamagedIdentityNeverSilentlyRotates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeDeviceStore(root: root, namespace: "one")
        _ = try store.loadOrCreate()
        try Data("damaged identity".utf8).write(to: store.file)
        #expect(throws: (any Error).self) { try store.loadOrCreate() }
        #expect(try Data(contentsOf: store.file) == Data("damaged identity".utf8))
    }
}
