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

    @Test func anIdentitySymlinkIsRefusedWithoutTouchingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeDeviceStore(root: root, namespace: "one")
        _ = try store.loadOrCreate()
        let target = root.appendingPathComponent("other-identity")
        let bytes = Data("other identity".utf8)
        try bytes.write(to: target)
        try FileManager.default.removeItem(at: store.file)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store.loadOrCreate() }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func theProcessLockExcludesAnotherWriterAndReleasesExplicitly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeDeviceStore(root: root, namespace: "one")
        var lock: NativeDeviceLock? = try store.lock()
        withExtendedLifetime(lock) { #expect(throws: NativeDeviceEnrollmentError.busy) { try store.lock() } }
        lock = nil
        let next = try store.lock()
        withExtendedLifetime(next) {}
    }

    @Test func secureCheckpointsContainNoPrivateKeyAndRecoverALostFileWithoutRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = MemoryNativeDeviceSecret()
        let store = NativeDeviceStore(root: root, namespace: "one", secret: secret)
        let record = try store.loadOrCreate()
        let bytes = try Data(contentsOf: store.file)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(record.privateKey))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("privateKey"))
        try FileManager.default.removeItem(at: store.file)
        #expect(try store.loadOrCreate().privateKey == record.privateKey)
        secret.erase()
        #expect(throws: NativeDeviceEnrollmentError.invalidState) { try store.loadOrCreate() }
    }
}

private final class MemoryNativeDeviceSecret: NativeDeviceSecret, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    func load(namespace: String, create: Bool) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let key = keys[namespace] { return key }
        guard create else { throw NativeDeviceEnrollmentError.invalidState }
        let key = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        keys[namespace] = key
        return key
    }
    func erase() { lock.lock(); keys = [:]; lock.unlock() }
}
