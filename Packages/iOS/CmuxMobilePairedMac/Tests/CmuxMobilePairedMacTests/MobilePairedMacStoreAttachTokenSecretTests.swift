import CMUXMobileCore
import Foundation
import SQLite3
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacStoreAttachTokenSecretTests {
    @Test func attachTokenSecretStaysOutOfSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let secretStore = InMemoryAttachTokenSecretStore()
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)

        let store = try MobilePairedMacStore(databaseURL: url, attachTokenSecrets: secretStore)
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "ticket-secret",
            attachTokenExpiresAt: expiresAt,
            attachTokenWorkspaceID: "workspace-a",
            attachTokenTerminalID: "terminal-a",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )

        let saved = try #require(try await store.activeMac(stackUserID: "user-1", teamID: "team-a"))
        #expect(saved.attachToken == "ticket-secret")
        #expect(secretStore.snapshot().values.sorted() == ["ticket-secret"])
        #expect(try sqliteAttachTokens(at: url) == [nil])
    }

    @Test func removingMacDeletesAttachTokenSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let secretStore = InMemoryAttachTokenSecretStore()
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )

        let store = try MobilePairedMacStore(databaseURL: url, attachTokenSecrets: secretStore)
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "ticket-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            attachTokenWorkspaceID: "workspace-a",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )

        try await store.remove(macDeviceID: "mac-a", stackUserID: "user-1", teamID: "team-a")

        #expect(secretStore.snapshot().isEmpty)
        #expect(try await store.loadAll(stackUserID: "user-1", teamID: "team-a").isEmpty)
    }

    @Test func claimingLegacyRowWithFreshTokenDeletesLegacySecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let secretStore = InMemoryAttachTokenSecretStore()
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        let store = try MobilePairedMacStore(databaseURL: url, attachTokenSecrets: secretStore)

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "legacy-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            attachTokenWorkspaceID: "",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "fresh-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_003_600),
            attachTokenWorkspaceID: "workspace-a",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        let saved = try #require(try await store.activeMac(stackUserID: "user-1", teamID: "team-a"))
        #expect(saved.attachToken == "fresh-secret")
        #expect(secretStore.snapshot().values.sorted() == ["fresh-secret"])
    }

    @Test func failedUpsertDeletesNewAttachTokenSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let secretStore = InMemoryAttachTokenSecretStore()
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        let store = try MobilePairedMacStore(databaseURL: url, attachTokenSecrets: secretStore)
        _ = try await store.loadAll()
        try await store.exec("DROP TABLE mac_routes;")

        await #expect(throws: (any Error).self) {
            try await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Mac A",
                routes: [route],
                attachToken: "ticket-secret",
                attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                attachTokenWorkspaceID: "",
                attachTokenTerminalID: nil,
                markActive: true,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: 1)
            )
        }
        #expect(secretStore.snapshot().isEmpty)
    }

    @Test func failedAttachTokenRefreshPreservesExistingSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let secretStore = InMemoryAttachTokenSecretStore()
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        let store = try MobilePairedMacStore(databaseURL: url, attachTokenSecrets: secretStore)
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "existing-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            attachTokenWorkspaceID: "workspace-a",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )

        secretStore.rejectSaves = true
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "fresh-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_003_600),
            attachTokenWorkspaceID: "workspace-fresh",
            attachTokenTerminalID: "terminal-fresh",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        let saved = try #require(try await store.activeMac(stackUserID: "user-1", teamID: "team-a"))
        #expect(saved.attachToken == "existing-secret")
        #expect(saved.attachTokenWorkspaceID == "workspace-a")
        #expect(saved.attachTokenTerminalID == nil)
        #expect(secretStore.snapshot().values.sorted() == ["existing-secret"])
    }

    @Test func failedUpsertAfterAttachTokenRefreshRestoresExistingSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let secretStore = InMemoryAttachTokenSecretStore()
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        let store = try MobilePairedMacStore(databaseURL: url, attachTokenSecrets: secretStore)
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "existing-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            attachTokenWorkspaceID: "workspace-a",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await store.exec("DROP TABLE mac_routes;")

        await #expect(throws: (any Error).self) {
            try await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Mac A",
                routes: [route],
                attachToken: "fresh-secret",
                attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_003_600),
                attachTokenWorkspaceID: "workspace-fresh",
                attachTokenTerminalID: "terminal-fresh",
                markActive: true,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: 2)
            )
        }

        #expect(secretStore.snapshot().values.sorted() == ["existing-secret"])
    }

    @Test func failedLegacyClaimDeletesCopiedAttachTokenSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let secretStore = InMemoryAttachTokenSecretStore()
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        let store = try MobilePairedMacStore(databaseURL: url, attachTokenSecrets: secretStore)
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "legacy-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            attachTokenWorkspaceID: "",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await store.exec("DROP TABLE mac_routes;")

        await #expect(throws: (any Error).self) {
            try await store.upsert(
                macDeviceID: "mac-a",
                displayName: "Mac A",
                routes: [route],
                attachToken: nil,
                attachTokenExpiresAt: nil,
                attachTokenWorkspaceID: nil,
                attachTokenTerminalID: nil,
                markActive: true,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: 2)
            )
        }
        #expect(secretStore.snapshot().values.sorted() == ["legacy-secret"])
    }

    @Test func inFlightAttachTokenUpsertDoesNotRecreateRemovedMac() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let secretStore = ReentrantAttachTokenSecretStore()
        let removalCompletion = RemovalCompletion()
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        let store = try MobilePairedMacStore(databaseURL: url, attachTokenSecrets: secretStore)
        secretStore.onSave = {
            Task {
                try? await store.remove(macDeviceID: "mac-a", stackUserID: "user-1", teamID: "team-a")
                await removalCompletion.finish()
            }
        }
        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "ticket-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            attachTokenWorkspaceID: "",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        await removalCompletion.wait()

        #expect(try await store.loadAll(stackUserID: "user-1", teamID: "team-a").isEmpty)
        #expect(secretStore.snapshot().isEmpty)
    }

    private func sqliteAttachTokens(at url: URL) throws -> [String?] {
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT attach_token FROM paired_macs;", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var values: [String?] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else {
                values.append(nil)
                continue
            }
            values.append(String(cString: cString))
        }
        return values
    }
}
