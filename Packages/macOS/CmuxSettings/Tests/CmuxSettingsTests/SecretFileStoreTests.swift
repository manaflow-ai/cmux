import Foundation
import Testing

@testable import CmuxSettings

@Suite struct SecretFileStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-secret-store-\(UUID().uuidString)", isDirectory: true)
    }

    private let key = SecretFileKey(id: "automation.socketPassword", fileName: "socket-control-password")

    @Test func returnsDefaultWhenAbsent() async throws {
        let store = SecretFileStore(baseDirectory: tempDir())
        #expect(try await store.value(for: key) == "")
        #expect(await store.hasValue(for: key) == false)
    }

    @Test func setLoadResetRoundTrip() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretFileStore(baseDirectory: dir)

        try await store.set("hunter2", for: key)
        #expect(try await store.value(for: key) == "hunter2")
        #expect(await store.hasValue(for: key))

        try await store.reset(key)
        #expect(try await store.value(for: key) == "")
        #expect(await store.hasValue(for: key) == false)
    }

    @Test func hasValueIgnoresNonEmptyDefault() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyWithDefault = SecretFileKey(
            id: "x.withDefault",
            fileName: "x-with-default",
            defaultValue: "fallback"
        )
        let store = SecretFileStore(baseDirectory: dir)
        // No file written: value() returns the default, but the secret is absent.
        #expect(try await store.value(for: keyWithDefault) == "fallback")
        #expect(await store.hasValue(for: keyWithDefault) == false)

        try await store.set("real", for: keyWithDefault)
        #expect(await store.hasValue(for: keyWithDefault))
    }

    @Test func writesOwnerOnlyPermissions() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretFileStore(baseDirectory: dir)
        try await store.set("secret", for: key)

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL(for: key).path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    @Test func emptyValueClears() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretFileStore(baseDirectory: dir)
        try await store.set("secret", for: key)
        try await store.set("\n", for: key)
        #expect(try await store.value(for: key) == "")
    }

    @Test func trimsTrailingNewline() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretFileStore(baseDirectory: dir)
        try await store.set("secret\n", for: key)
        #expect(try await store.value(for: key) == "secret")
    }

    @Test func valuesStreamYieldsCurrentThenChange() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretFileStore(baseDirectory: dir)
        try await store.set("first", for: key)

        var iterator = store.values(for: key).makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial == "first")

        try await store.set("second", for: key)
        let updated = await iterator.next()
        #expect(updated == "second")
    }
}
