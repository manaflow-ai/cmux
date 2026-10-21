import Foundation
@testable import CmuxNextUpdater
import Testing

/// The web updater (plans/cmux-next/web-ota.md) against a fake files.cmux.com: it takes a newer
/// signed update and hands its tree to the app; it never downloads one this app's native code
/// cannot run, one older than the bundled web, or one it rolled back; an unchanged pointer is a
/// conditional read.
@Suite(.serialized) @MainActor struct WebUpdaterTests {
    /// What the fake server serves and saw.
    final class Server: @unchecked Sendable {
        var pointer = Data()
        var archive: URL?
        var etag = "\"1\""
        var pointerReads = 0
        var downloads = 0
    }

    static func pointerData(_ pointer: WebUpdatePointer) throws -> Data {
        var payload = WebUpdatePointerTests.payload(key: pointer.key, abi: pointer.abi, committedAt: pointer.committedAt,
                                                    sha: pointer.sha256, outputs: pointer.outputs, size: pointer.size)
        payload["published_at"] = pointer.publishedAt
        return try WebUpdatePointerTests.envelope(payload)
    }

    static func updater(_ server: Server, store: WebUpdateStore, app: WebUpdater.App = .init(abi: 2, webBuiltAt: 1_700_000_000)) -> WebUpdater {
        let updater = WebUpdater(
            store: store, app: app, keys: WebUpdatePointerTests.keys,
            fetch: { request in
                server.pointerReads += 1
                let url = try #require(request.url)
                if request.value(forHTTPHeaderField: "If-None-Match") == server.etag {
                    return (Data(), HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: nil)!)
                }
                return (server.pointer, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": server.etag])!)
            },
            download: { _ in
                server.downloads += 1
                let source = try #require(server.archive)
                let copy = FileManager.default.temporaryDirectory.appending(path: "WebUpdaterTests-\(UUID().uuidString).tar.gz")
                try FileManager.default.copyItem(at: source, to: copy)
                return copy
            })
        updater.channel = .everyMerge
        return updater
    }

    @Test func aNewerUpdateIsTakenAndHandedToTheApp() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(pointer)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = Self.updater(server, store: store)
        var ready: [URL?] = []
        updater.onReady = { ready.append($0) }
        await updater.check()
        #expect(updater.phase == .idle)
        #expect(updater.state.active == pointer)
        #expect(ready == [store.tree(for: pointer.key).root])
        #expect(store.readState().floor == pointer.committedAt)
        // The same pointer again: a conditional read, no download.
        await updater.check()
        #expect(server.pointerReads == 2)
        #expect(server.downloads == 1)
        // A restarted updater (no ETag) refuses the update it already serves.
        let again = Self.updater(server, store: store)
        _ = await again.launchTree()
        await again.check()
        #expect(again.lastRefusal == .notNewer)
        #expect(server.downloads == 1)
    }

    @Test func anUpdateForOtherNativeCodeIsNeverDownloaded() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(pointer)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = Self.updater(server, store: store, app: .init(abi: 3, webBuiltAt: 1_700_000_000))
        await updater.check()
        #expect(updater.lastRefusal == .abiMismatch(update: 2, app: 3))
        #expect(updater.phase == .idle)
        #expect(server.downloads == 0)
        #expect(updater.state.active == nil)
    }

    @Test func anUpdateOlderThanTheBundledWebIsNotTaken() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(pointer)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = Self.updater(server, store: store, app: .init(abi: 2, webBuiltAt: pointer.committedAt))
        await updater.check()
        #expect(updater.lastRefusal == .notNewer)
        #expect(server.downloads == 0)
    }

    @Test func aRollBackServesThePreviousUpdateAndRefusesTheRolledBackOne() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, first) = try await WebUpdateStoreTests.makeArchive(in: root)
        var second = first
        second.key = String(repeating: "e", count: 64)
        second.committedAt = first.committedAt + 100
        let server = Server()
        server.archive = archive
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = Self.updater(server, store: store)
        var ready: [URL?] = []
        updater.onReady = { ready.append($0) }
        server.pointer = try Self.pointerData(first)
        await updater.check()
        server.pointer = try Self.pointerData(second)
        server.etag = "\"2\""
        await updater.check()
        #expect(updater.state.active == second)
        #expect(updater.state.previous == first)

        try await updater.rollBack()
        #expect(updater.state.active == first)
        #expect(ready.last == store.tree(for: first.key).root)
        #expect(!FileManager.default.fileExists(atPath: store.tree(for: second.key).root.path))
        server.etag = "\"3\""
        await updater.check()
        #expect(updater.lastRefusal == .notNewer)
        #expect(updater.state.active == first)

        // Back to the bundled web.
        try await updater.rollBack()
        #expect(updater.state.active == nil)
        #expect(ready.last == .some(nil))
    }

    @Test func aPointerSignedByAnotherKeyFailsTheCheck() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = Server()
        server.archive = archive
        var payload = WebUpdatePointerTests.payload(key: pointer.key, sha: pointer.sha256, outputs: pointer.outputs, size: pointer.size)
        payload["committed_at"] = pointer.committedAt
        server.pointer = try WebUpdatePointerTests.envelope(payload, key: .init())
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = Self.updater(server, store: store)
        await updater.check()
        #expect(updater.lastRefusal == .unsigned)
        #expect(updater.phase == .failed(String(describing: WebUpdateRefusal.unsigned)))
        #expect(server.downloads == 0)
    }
}
