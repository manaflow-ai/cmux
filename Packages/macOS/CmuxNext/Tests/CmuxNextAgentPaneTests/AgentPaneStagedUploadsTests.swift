import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The staged-upload store the Cloud and peer stagers share: a file of any size is staged, a batch
/// stays authorized while its stages live, and a cancel during the transfer stops it before the
/// staged file goes.
@MainActor @Suite struct AgentPaneStagedUploadsTests {
    static let work = BackgroundWork(label: "test.staged-uploads")

    private static func stageFile(_ token: String) -> (file: URL, removing: URL)? {
        let file = FileManager.default.temporaryDirectory.appending(path: "staged-uploads-test-" + token)
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        return (file, file)
    }

    @Test(arguments: [(1 << 30) + 1, 8 << 30])
    func aBeginOfAnySizeIsTaken(size: Int) async throws {
        #expect(AgentPaneStagedUploads<String>.acceptsBegin(name: "big.bin", size: size, manifest: nil))
        let batch = [AgentPaneUploadBatchEntry(name: "big.bin", size: size), AgentPaneUploadBatchEntry(name: "next.bin", size: size)]
        #expect(AgentPaneStagedUploads<String>.acceptsBegin(name: "big.bin", size: size, manifest: batch))
        #expect(!AgentPaneStagedUploads<String>.acceptsBegin(name: "big.bin", size: -1, manifest: nil))
        #expect(!AgentPaneStagedUploads<String>.acceptsBegin(name: "next.bin", size: size, manifest: batch))
        let store = AgentPaneStagedUploads<String>(owner: "test.staged-uploads.any-size")
        let begun = try #require(store.begin(name: "big.bin", size: size, batchToken: nil, manifest: nil, target: "a", work: Self.work, make: Self.stageFile))
        await store.cancel(begun.token, owns: { $0 == "a" }, work: Self.work)
    }

    /// A batch takes its files in order, only while authorized, and only once each.
    @Test func aBatchTakesItsFilesInOrderOnce() async throws {
        let store = AgentPaneStagedUploads<String>(owner: "test.staged-uploads.batch")
        let batch = [AgentPaneUploadBatchEntry(name: "a.bin", size: 1), AgentPaneUploadBatchEntry(name: "b.bin", size: 2)]
        let first = try #require(store.begin(name: "a.bin", size: 1, batchToken: nil, manifest: batch, target: "t", work: Self.work, make: Self.stageFile))
        let token = try #require(first.batchToken)
        #expect(store.batchTarget(token, name: "a.bin", size: 1) == nil)
        #expect(store.batchTarget(token, name: "b.bin", size: 2) == "t")
        let second = try #require(store.begin(name: "b.bin", size: 2, batchToken: token, manifest: nil, target: "t", work: Self.work, make: Self.stageFile))
        #expect(second.batchToken == token)
        #expect(store.begin(name: "b.bin", size: 2, batchToken: token, manifest: nil, target: "t", work: Self.work, make: Self.stageFile) == nil)
        await store.cancel(first.token, owns: { _ in true }, work: Self.work)
        await store.cancel(second.token, owns: { _ in true }, work: Self.work)
    }

    /// Chunks append in order and up to the declared size; another target's request is refused.
    @Test func chunksAppendInOrderForTheirOwnTarget() async throws {
        let store = AgentPaneStagedUploads<String>(owner: "test.staged-uploads.chunks")
        let begun = try #require(store.begin(name: "c.bin", size: 3, batchToken: nil, manifest: nil, target: "mine", work: Self.work, make: Self.stageFile))
        let mine = { (target: String) in target == "mine" }
        #expect(store.chunk(begun.token, offset: 0, data: Data([1, 2]), owns: { $0 == "other" }, work: Self.work) == nil)
        #expect(store.chunk(begun.token, offset: 1, data: Data([1]), owns: mine, work: Self.work) == nil)
        #expect(store.chunk(begun.token, offset: 0, data: Data([1, 2]), owns: mine, work: Self.work) == 2)
        #expect(store.chunk(begun.token, offset: 2, data: Data([3, 4]), owns: mine, work: Self.work) == nil)
        #expect(store.chunk(begun.token, offset: 2, data: Data([3]), owns: mine, work: Self.work) == 3)
        let read = await store.finish(begun.token, owns: mine, work: Self.work) { staged in
            (try? Data(contentsOf: staged.file)) ?? Data()
        }
        #expect(read == Data([1, 2, 3]))
        let again = await store.finish(begun.token, owns: mine, work: Self.work) { _ in Data() }
        #expect(again == nil)
    }

    /// A cancel while the transfer reads the staged file stops the transfer first; the file is gone
    /// when the cancel returns, and the transfer never saw it removed.
    @Test func cancellingDuringTheTransferStopsItBeforeTheFileGoes() async throws {
        let store = AgentPaneStagedUploads<String>(owner: "test.staged-uploads.cancel")
        let begun = try #require(store.begin(name: "slow.bin", size: 1, batchToken: nil, manifest: nil, target: "t", work: Self.work, make: Self.stageFile))
        #expect(store.chunk(begun.token, offset: 0, data: Data([1]), owns: { _ in true }, work: Self.work) == 1)
        let (started, starting) = AsyncStream.makeStream(of: URL.self)
        let finishing = Task { @MainActor in
            await store.finish(begun.token, owns: { _ in true }, work: Self.work) { staged -> Bool in
                starting.yield(staged.file)
                // The file is still there when the cancel stops the transfer.
                do { try await Task.sleep(for: .seconds(3_600)) } catch { return FileManager.default.fileExists(atPath: staged.file.path) }
                return false
            }
        }
        var iterator = started.makeAsyncIterator()
        let next = await iterator.next()
        let file = try #require(next)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await store.cancel(begun.token, owns: { _ in true }, work: Self.work)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let sawFile = await finishing.value
        #expect(sawFile == true)
    }

    /// A cancel that comes after the transfer delivered the file (the chip's x as the answer comes
    /// back) takes the delivery back, once and only for its own target; a failed transfer has none.
    @Test func aCancelAfterDeliveryTakesItBack() async throws {
        let store = AgentPaneStagedUploads<String>(owner: "test.staged-uploads.undo")
        let undone = UndoLog()
        for (name, delivers) in [("sent.bin", true), ("failed.bin", false)] {
            let begun = try #require(store.begin(name: name, size: 1, batchToken: nil, manifest: nil, target: "t", work: Self.work, make: Self.stageFile))
            #expect(store.chunk(begun.token, offset: 0, data: Data([1]), owns: { _ in true }, work: Self.work) == 1)
            let answer = await store.finish(begun.token, owns: { _ in true }, work: Self.work, transfer: { _ in delivers },
                                            undo: { delivered in delivered ? { @MainActor in undone.add(name) } : nil })
            #expect(answer == delivers)
            let before = undone.names
            await store.cancel(begun.token, owns: { $0 == "other" }, work: Self.work)
            #expect(undone.names == before, "another target's cancel took back \(name)")
            await store.cancel(begun.token, owns: { $0 == "t" }, work: Self.work)
            await store.cancel(begun.token, owns: { $0 == "t" }, work: Self.work)
        }
        #expect(undone.names == ["sent.bin"])
    }
}

/// The names a test's undo ran for, on the main actor as the store runs undo.
@MainActor private final class UndoLog {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
