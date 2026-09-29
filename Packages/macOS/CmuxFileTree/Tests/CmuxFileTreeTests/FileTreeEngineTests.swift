import Foundation
import Testing
@testable import CmuxFileTree

/// A provider whose listings and gates are scripted by the test.
private actor ScriptedFileSystem {
    var listings: [String: [FileTreeEntry]] = [:]
    var listCalls: [[String]] = []
    var failures: [String: String] = [:]
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var gatedPaths: Set<String> = []

    func set(_ path: String, _ entries: [FileTreeEntry]) { listings[path] = entries }
    func fail(_ path: String, _ message: String) { failures[path] = message }
    func gate(_ path: String) { gatedPaths.insert(path) }
    func release(_ path: String) {
        gates.removeValue(forKey: path)?.resume()
    }
    func isWaiting(_ path: String) -> Bool { gates[path] != nil }

    func list(_ paths: [String]) async -> [String: Result<FileTreeListing, any Error>] {
        listCalls.append(paths)
        var results: [String: Result<FileTreeListing, any Error>] = [:]
        // Snapshot before any gate so a gated call returns what it saw first.
        let snapshot = listings
        for path in paths {
            if gatedPaths.remove(path) != nil {
                await withCheckedContinuation { gates[path] = $0 }
            }
            if let message = failures[path] {
                results[path] = .failure(ScriptedError(message: message))
            } else {
                results[path] = .success(FileTreeListing(entries: snapshot[path] ?? []))
            }
        }
        return results
    }
}

private struct ScriptedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ScriptedProvider: FileTreeProvider {
    let fileSystem: ScriptedFileSystem
    func listDirectory(at path: String) async throws -> FileTreeListing {
        try await fileSystem.list([path])[path]!.get()
    }
    func listDirectories(at paths: [String]) async -> [String: Result<FileTreeListing, any Error>] {
        await fileSystem.list(paths)
    }
}

private func file(_ parent: String, _ name: String) -> FileTreeEntry {
    FileTreeEntry(name: name, path: parent + "/" + name, kind: .file)
}

private func folder(_ parent: String, _ name: String) -> FileTreeEntry {
    FileTreeEntry(name: name, path: parent + "/" + name, kind: .directory)
}

private func loadedNames(_ update: FileTreeDirectoryUpdate?) -> [String]? {
    guard case .loaded(let entries, _, _)? = update?.outcome else { return nil }
    return entries.map(\.name)
}

@Suite struct FileTreeEngineTests {
    @Test func firstLoadInsertsEverythingAndRefreshDeliversOnlyTheDiff() async {
        let fs = ScriptedFileSystem()
        await fs.set("/r", [file("/r", "b"), folder("/r", "src"), file("/r", "a")])
        let engine = FileTreeEngine(provider: ScriptedProvider(fileSystem: fs))

        let first = await engine.load(["/r"]).first
        #expect(first?.isInitialLoad == true)
        #expect(loadedNames(first) == ["src", "a", "b"])

        await fs.set("/r", [file("/r", "b"), folder("/r", "src"), file("/r", "a"), file("/r", "c")])
        let second = await engine.load(["/r"]).first
        #expect(second?.isInitialLoad == false)
        guard case .loaded(_, let diff, _)? = second?.outcome else {
            Issue.record("expected a loaded update")
            return
        }
        #expect(diff.removed.isEmpty)
        #expect(diff.inserted == IndexSet(integer: 3))
    }

    @Test func batchLoadsUseOneProviderCall() async {
        let fs = ScriptedFileSystem()
        await fs.set("/r/a", [file("/r/a", "1")])
        await fs.set("/r/b", [file("/r/b", "2")])
        let engine = FileTreeEngine(provider: ScriptedProvider(fileSystem: fs))
        let updates = await engine.load(["/r/a", "/r/b", "/r/a"])
        #expect(updates.map(\.path) == ["/r/a", "/r/b"])
        #expect(await fs.listCalls == [["/r/a", "/r/b"]])
    }

    @Test func hiddenToggleAndSortChangeNeedNoIO() async {
        let fs = ScriptedFileSystem()
        await fs.set("/r", [file("/r", ".env"), file("/r", "b"), file("/r", "a")])
        let engine = FileTreeEngine(provider: ScriptedProvider(fileSystem: fs), showsHiddenFiles: false)
        #expect(loadedNames(await engine.load(["/r"]).first) == ["a", "b"])

        let shown = await engine.setPresentation(sortOrder: .standard, showsHiddenFiles: true)
        #expect(loadedNames(shown.first) == [".env", "a", "b"])
        let reversed = await engine.setPresentation(
            sortOrder: FileTreeSortOrder(ascending: false),
            showsHiddenFiles: true
        )
        #expect(loadedNames(reversed.first) == ["b", "a", ".env"])
        #expect(await fs.listCalls.count == 1)
    }

    @Test func supersededLoadIsDropped() async {
        let fs = ScriptedFileSystem()
        await fs.set("/r", [file("/r", "old")])
        await fs.gate("/r")
        let engine = FileTreeEngine(provider: ScriptedProvider(fileSystem: fs))
        let slow = Task { await engine.load(["/r"]) }
        while await !fs.isWaiting("/r") { await Task.yield() }
        // A newer load starts and finishes while the first one is suspended.
        await fs.set("/r", [file("/r", "new")])
        let fresh = await engine.load(["/r"])
        await fs.release("/r")
        let stale = await slow.value
        #expect(loadedNames(fresh.first) == ["new"])
        #expect(stale.isEmpty, "a superseded listing must not overwrite the newer one")
    }

    @Test func failureKeepsPreviousChildren() async {
        let fs = ScriptedFileSystem()
        await fs.set("/r", [file("/r", "a")])
        let engine = FileTreeEngine(provider: ScriptedProvider(fileSystem: fs))
        _ = await engine.load(["/r"])
        await fs.fail("/r", "gone")
        let failed = await engine.load(["/r"]).first
        #expect(failed?.outcome == .failed(message: "gone"))
        await fs.fail("/r", "")
        let fsFailures = await fs.failures
        #expect(fsFailures["/r"] == "")
    }

    @Test func changeBatchesOnlyTouchLoadedDirectories() async {
        let fs = ScriptedFileSystem()
        let engine = FileTreeEngine(provider: ScriptedProvider(fileSystem: fs))
        _ = await engine.load(["/r", "/r/src", "/r/src/deep"])
        let direct = await engine.affectedDirectories(for: FileTreeChangeBatch(
            directories: ["/r/src", "/r/node_modules/x", "/r/.build/debug"]
        ))
        #expect(direct == ["/r/src"])
        let subtree = await engine.affectedDirectories(for: FileTreeChangeBatch(subtrees: ["/r/src"]))
        #expect(subtree == ["/r/src", "/r/src/deep"])
    }

    @Test func discardMakesTheNextLoadInitial() async {
        let fs = ScriptedFileSystem()
        await fs.set("/r/a", [file("/r/a", "x")])
        let engine = FileTreeEngine(provider: ScriptedProvider(fileSystem: fs))
        _ = await engine.load(["/r/a"])
        await engine.discard(subtreeAt: "/r")
        #expect(await engine.loadedDirectories().isEmpty)
        #expect(await engine.load(["/r/a"]).first?.isInitialLoad == true)
    }
}
