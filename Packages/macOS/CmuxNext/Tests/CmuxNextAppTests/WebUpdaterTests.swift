import Foundation
@testable import CmuxNextUpdater
import Testing

/// The web updater (plans/cmux-next/web-ota.md) against a fake files.cmux.com: it takes a newer
/// signed update and hands its tree to the app; it never downloads one this app's native code
/// cannot run, one older than the bundled web, or one it rolled back; an unchanged pointer is a
/// conditional read.
@Suite(.serialized) @MainActor struct WebUpdaterTests {
    /// What the fake server serves and saw.
    nonisolated final class Server: @unchecked Sendable {
        var pointer = Data()
        var archive: URL?
        var etag = "\"1\""
        var pointerReads = 0
        var downloads = 0
        /// Downloads still to fail.
        var failures = 0
        /// Runs at the start of each download (a test holds one there).
        var hold: (@Sendable () async -> Void)?
        /// The `cas/1` fetches asked for (RFD 0166).
        var casRequests: [WebUpdater.CasRequest] = []
    }

    static func pointerData(_ pointer: WebUpdatePointer) throws -> Data {
        var payload = WebUpdatePointerTests.payload(key: pointer.key, abi: pointer.abi, committedAt: pointer.committedAt,
                                                    sha: pointer.sha256, outputs: pointer.outputs, size: pointer.size)
        payload["published_at"] = pointer.publishedAt
        if let cas = pointer.cas { payload["cas"] = ["prefix": cas.prefix, "manifest": cas.manifest, "pack": cas.pack] }
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
                await server.hold?()
                if server.failures > 0 {
                    server.failures -= 1
                    throw URLError(.networkConnectionLost)
                }
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
        updater.onReady = { tree, _ in ready.append(tree) }
        await updater.check()
        #expect(updater.phase == .idle)
        #expect(updater.state.active == pointer)
        #expect(ready == [store.tree(for: pointer.key).root])
        #expect(store.readState().floor == pointer.committedAt)
        // The same pointer again: a conditional read, no download.
        await updater.check()
        #expect(server.pointerReads == 2)
        #expect(server.downloads == 1)
        // A restarted updater (no ETag) refuses the update it already serves, also when its
        // first check starts before the launch check read the kept state.
        let again = Self.updater(server, store: store)
        await again.check()
        #expect(again.lastRefusal == .notNewer)
        #expect(again.state.active == pointer)
        #expect(server.downloads == 1)
        #expect(await again.launchTree() == store.tree(for: pointer.key).root)
        #expect(again.launchVersion == pointer)
    }

    @Test func offAtLaunchServesTheBundledWeb() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(pointer)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        await Self.updater(server, store: store).check()
        #expect(store.readState().active == pointer)
        // Relaunched with `updates.web: off`: the kept update is not served.
        let again = Self.updater(server, store: store)
        again.follow(.off)
        #expect(await again.launchTree() == nil)
        #expect(again.state.active == nil)
        #expect(store.readState().active == nil)
    }

    /// The first launch after an app update that shipped newer web: pages get the bundle at once,
    /// the kept tree goes after, and a check that takes a newer update right away keeps its tree
    /// (it waits for that removal before it unpacks, so the removal cannot take the new tree).
    @Test func aLaunchThatDropsTheKeptUpdateRemovesItsTreeAfterTheAnswer() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, old) = try await WebUpdateStoreTests.makeArchive(in: root)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let dropped = try await store.install(archive: archive, pointer: old)
        try store.write(WebUpdateState(active: old, floor: old.committedAt))
        var newer = old
        newer.committedAt = old.committedAt + 100
        newer.publishedAt = newer.committedAt + 60
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(newer)
        // The new app's web was built after the kept update's commit, before the newer one's.
        let updater = Self.updater(server, store: store, app: .init(abi: 2, webBuiltAt: old.committedAt + 1))
        var ready: [URL?] = []
        updater.onReady = { tree, _ in ready.append(tree) }
        #expect(await updater.launchTree() == nil)
        #expect(store.readState().active == nil)
        await updater.check()
        #expect(updater.state.active == newer)
        #expect(ready == [dropped])
        #expect(store.verifiedTree(newer) == dropped)
        // The same key went and came back; with nothing kept, the launch prune leaves no tree.
        let empty = WebUpdateStore(base: root.appending(path: "empty", directoryHint: .isDirectory))
        let kept = try await empty.install(archive: archive, pointer: old)
        try empty.write(WebUpdateState(active: old, floor: old.committedAt))
        let quiet = Self.updater(server, store: empty, app: .init(abi: 2, webBuiltAt: old.committedAt + 1))
        quiet.follow(.off)
        #expect(await quiet.launchTree() == nil)
        await quiet.launchSettled()
        #expect(!FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func aKeptUpdateFromAnotherChannelIsNotServedAtLaunch() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(pointer)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        await Self.updater(server, store: store).check()
        // Relaunched following the nightly channel: the every-merge update is not served.
        let again = Self.updater(server, store: store)
        again.follow(.nightly)
        #expect(await again.launchTree() == nil)
        #expect(store.readState().active == nil)
    }

    @Test func aFailedDownloadIsTriedAgain() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(pointer)
        server.failures = 1
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = Self.updater(server, store: store)
        await updater.check()
        #expect(updater.state.active == nil)
        #expect(updater.phase != .idle)
        // The pointer did not change, but the update was never taken: the next check reads it in full.
        await updater.check()
        #expect(server.downloads == 2)
        #expect(updater.state.active == pointer)
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

    /// The switch file of web pieces refuses the update (`cmux app web-pieces refused`): it is
    /// never downloaded or made active, so no page serves it before a pieces read rolls it back.
    @Test func anUpdateTheSwitchFileRefusesIsNeverDownloadedOrMadeActive() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(pointer)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = Self.updater(server, store: store)
        var ready: [URL?] = []
        var asked: [WebUpdatePointer] = []
        updater.onReady = { tree, _ in ready.append(tree) }
        updater.refuses = { pointer in
            asked.append(pointer)
            return true
        }
        await updater.check()
        #expect(asked == [pointer])
        #expect(updater.state.active == nil)
        #expect(store.readState().active == nil)
        #expect(ready.isEmpty)
        #expect(server.downloads == 0)
        #expect(updater.lastRefusal == .refusedBySwitchFile)
        #expect(updater.phase == .idle)
        // The same pointer: not asked again until it changes.
        await updater.check()
        #expect(asked.count == 1)
        // A later switch file allows it: taken when the pointer is read again.
        updater.refuses = { _ in false }
        server.etag = "\"2\""
        await updater.check()
        #expect(updater.state.active == pointer)
        #expect(server.downloads == 1)
        #expect(ready == [store.tree(for: pointer.key).root])
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
        updater.onReady = { tree, _ in ready.append(tree) }
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

    @Test func aRollBackIsRefusedWhileACheckDownloads() async throws {
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
        server.pointer = try Self.pointerData(first)
        await updater.check()
        // The second check stops in its download until the test lets it go.
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (gate, open) = AsyncStream<Void>.makeStream()
        server.hold = {
            didStart.yield()
            for await _ in gate {}
        }
        server.pointer = try Self.pointerData(second)
        server.etag = "\"2\""
        let check = Task { await updater.check() }
        for await _ in started { break }
        #expect(updater.phase == .downloading)
        await #expect(throws: WebUpdater.Busy.self) { try await updater.rollBack() }
        open.finish()
        await check.value
        #expect(updater.state.active == second)
        // Once the check ends, the roll back goes through.
        try await updater.rollBack()
        #expect(updater.state.active == first)
    }

    @Test func turningUpdatesOffDuringARollBackServesTheBundledWeb() async throws {
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
        var ready: [WebUpdatePointer?] = []
        updater.onReady = { _, pointer in ready.append(pointer) }
        server.pointer = try Self.pointerData(first)
        await updater.check()
        server.pointer = try Self.pointerData(second)
        server.etag = "\"2\""
        await updater.check()
        // Off, then a roll back before the channel's write ran: the roll back waits for it and
        // finds the bundled web, so it never brings an update back.
        updater.follow(.off)
        try await updater.rollBack()
        #expect(updater.state.active == nil)
        #expect(store.readState().active == nil)
        #expect(ready.last == .some(nil))
    }

    @Test func turningUpdatesOffDuringADownloadKeepsTheBundledWeb() async throws {
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
        var ready: [WebUpdatePointer?] = []
        updater.onReady = { _, pointer in ready.append(pointer) }
        server.pointer = try Self.pointerData(first)
        await updater.check()
        // The second check stops in its download; updates turn off meanwhile.
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (gate, open) = AsyncStream<Void>.makeStream()
        server.hold = {
            didStart.yield()
            for await _ in gate {}
        }
        server.pointer = try Self.pointerData(second)
        server.etag = "\"2\""
        let check = Task { await updater.check() }
        for await _ in started { break }
        updater.follow(.off)
        open.finish()
        await check.value
        // The check kept its result after the channel's write: the bundled web, on disk too.
        #expect(updater.state.active == nil)
        #expect(store.readState().active == nil)
        #expect(ready.last == .some(nil))
    }

    @Test func theServedTreeIsKeptUntilTheSafePointSwapsItOut() async throws {
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
        server.pointer = try Self.pointerData(first)
        await updater.check()
        server.pointer = try Self.pointerData(second)
        server.etag = "\"2\""
        await updater.check()
        // Pages still load the second update's files when it is rolled back.
        var served = [store.tree(for: second.key).root]
        updater.served = { served }
        try await updater.rollBack()
        #expect(FileManager.default.fileExists(atPath: store.tree(for: second.key).root.path))
        // New pages load the first one while an open page still reads the second: both stay.
        served = [store.tree(for: first.key).root, store.tree(for: second.key).root]
        await updater.pruneUnused()
        #expect(FileManager.default.fileExists(atPath: store.tree(for: second.key).root.path))
        // That page reloaded at its safe point: now the second goes.
        served = [store.tree(for: first.key).root]
        await updater.pruneUnused()
        #expect(!FileManager.default.fileExists(atPath: store.tree(for: second.key).root.path))
        #expect(FileManager.default.fileExists(atPath: store.tree(for: first.key).root.path))
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

    // MARK: cas/1 (RFD 0166): the tree by chunks when `casFetch` is set, the archive on any miss.

    static let cas = WebUpdatePointer.Cas(prefix: "cmux-next-web/cas/", manifest: String(repeating: "e", count: 64),
                                          pack: String(repeating: "f", count: 64))

    /// An updater whose pointer names `cas`, and whose fake fetch copies the fixture tree (`src`,
    /// which makeArchive wrote) into the request's folder, after `alter` changes the copy.
    static func casSetup(_ root: URL, result: Result<Void, WebUpdater.CasMiss> = .success(()), alter: Bool = false)
        async throws -> (Server, WebUpdateStore, WebUpdater, WebUpdatePointer) {
        var (archive, pointer) = try await WebUpdateStoreTests.makeArchive(in: root)
        pointer.cas = cas
        let server = Server()
        server.archive = archive
        server.pointer = try Self.pointerData(pointer)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let updater = Self.updater(server, store: store)
        let source = root.appending(path: "src", directoryHint: .isDirectory)
        updater.casFetch = { request in
            server.casRequests.append(request)
            if case .failure(let miss) = result { return .failure(miss) }
            do {
                try FileManager.default.createDirectory(at: request.chunks, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: request.out)
                if alter { try Data("changed".utf8).write(to: request.out.appending(path: "Native/changed.txt")) }
            } catch { return .failure(.init("copy: \(error)")) }
            return .success(.init(treeBytes: 100, chunks: 4, reused: 3, ranges: 1, rangeBytes: 25, metaBytes: 10))
        }
        return (server, store, updater, pointer)
    }

    static func staging(in store: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).filter { $0.hasPrefix("staging-") }
    }

    @Test func aCasTreeIsTakenWithoutTheArchive() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, store, updater, pointer) = try await Self.casSetup(root)
        var ready: [URL?] = []
        updater.onReady = { tree, _ in ready.append(tree) }
        await updater.check()
        #expect(server.downloads == 0)
        #expect(updater.state.active == pointer)
        #expect(ready == [store.tree(for: pointer.key).root])
        #expect(try WebUpdateTree(root: store.tree(for: pointer.key).root).outputDigest() == pointer.outputs)
        let request = try #require(server.casRequests.first)
        #expect(request.manifest == Self.cas.manifest && request.pack == Self.cas.pack)
        #expect(request.base.absoluteString == "https://files.cmux.com/cmux-next-web/cas/")
        #expect(request.have.isEmpty)
        #expect(updater.lastFetch?.by == .cas)
        #expect(updater.lastFetch?.cas?.rangeBytes == 25)
        #expect(Self.staging(in: root.appending(path: "store")).isEmpty)
    }

    @Test func aCasMissTakesTheArchiveInTheSameCheck() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, _, updater, pointer) = try await Self.casSetup(root, result: .failure(.init("metered link")))
        await updater.check()
        #expect(server.casRequests.count == 1)
        #expect(server.downloads == 1)
        #expect(updater.state.active == pointer)
        #expect(updater.lastFetch == .init(key: pointer.key, by: .archive, casMiss: "metered link", archiveBytes: pointer.size))
    }

    @Test func aCasTreeThatIsNotThePointersTakesTheArchive() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, store, updater, pointer) = try await Self.casSetup(root, alter: true)
        await updater.check()
        #expect(server.downloads == 1)
        #expect(updater.state.active == pointer)
        #expect(try WebUpdateTree(root: store.tree(for: pointer.key).root).outputDigest() == pointer.outputs)
        #expect(updater.lastFetch?.by == .archive)
        #expect(updater.lastFetch?.casMiss?.hasPrefix("tree: ") == true)
        #expect(Self.staging(in: root.appending(path: "store")).isEmpty)
    }

    @Test func withoutCasFetchOnlyTheArchiveIsRead() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, _, updater, pointer) = try await Self.casSetup(root)
        updater.casFetch = nil
        await updater.check()
        #expect(server.casRequests.isEmpty)
        #expect(server.downloads == 1)
        #expect(updater.lastFetch == .init(key: pointer.key, by: .archive, archiveBytes: pointer.size))
    }

    @Test func theReportIsTheOutputsLastLine() {
        let output = Data("note\n{\"ok\":true,\"tree_bytes\":9,\"chunks\":3,\"reused\":2,\"ranges\":1,\"range_bytes\":4,\"meta_bytes\":5}\n".utf8)
        #expect(WebUpdater.CasReport.parse(output) == .init(treeBytes: 9, chunks: 3, reused: 2, ranges: 1, rangeBytes: 4, metaBytes: 5))
        #expect(WebUpdater.CasReport.parse(Data("error: no\n".utf8)) == nil)
    }
}
