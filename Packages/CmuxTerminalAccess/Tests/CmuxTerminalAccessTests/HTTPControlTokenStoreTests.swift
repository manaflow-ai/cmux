// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct HTTPControlTokenStoreTests {
    private func makeStore() throws -> (HTTPControlTokenStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-httpctl-tok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let path = dir.appendingPathComponent("http-control-token")
        let store = HTTPControlTokenStore(fileURL: path)
        return (store, path)
    }

    @Test func ensureTokenGeneratesNonEmptyAt0600() throws {
        let (store, path) = try makeStore()
        let t = try store.ensureToken()
        #expect(!t.isEmpty)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test func ensureTokenReusesExisting() throws {
        let (store, _) = try makeStore()
        let t1 = try store.ensureToken()
        let t2 = try store.ensureToken()
        #expect(t1 == t2)
    }

    @Test func rotateTokenChangesValueAndPreserves0600() throws {
        let (store, path) = try makeStore()
        let t1 = try store.ensureToken()
        let t2 = try store.rotateToken()
        #expect(t1 != t2)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test func ensureTokenRepairsTooPermissiveFile() throws {
        let (store, path) = try makeStore()
        let t1 = try store.ensureToken()
        // Simulate an old token file written with the wrong mode.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: path.path
        )
        let t2 = try store.ensureToken()
        #expect(t1 == t2)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }
}
