import Foundation
import Testing

@testable import CmuxBrowser

/// A frame tree source that counts reads and can hold a read open.
@MainActor
private final class FakeFrameTree {
    var ids: [String]
    var reads = 0
    private var gate: CheckedContinuation<Void, Never>?
    var holdNextRead = false

    init(_ ids: [String]) { self.ids = ids }

    func read() async -> [String] {
        reads += 1
        if holdNextRead {
            holdNextRead = false
            await withCheckedContinuation { gate = $0 }
        }
        return ids
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
@Suite("Browser REPL frame registry")
struct BrowserReplFrameRegistryTests {
    private func registry(_ tree: FakeFrameTree) -> BrowserReplFrameRegistry<String> {
        BrowserReplFrameRegistry(id: { $0 }, read: { await tree.read() })
    }

    @Test("Hundreds of concurrent lookups share one tree read")
    func concurrentLookupsShareOneRead() async {
        let tree = FakeFrameTree((0..<401).map { "f\($0)" })
        let registry = registry(tree)
        tree.holdNextRead = true
        let lookups = Task { @MainActor in
            await withTaskGroup(of: String?.self) { group in
                for i in 0..<400 { group.addTask { @MainActor in await registry.frame("f\(i)") } }
                var found = 0
                for await frame in group where frame != nil { found += 1 }
                return found
            }
        }
        while tree.reads == 0 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        tree.release()
        #expect(await lookups.value == 400)
        #expect(tree.reads == 1)
    }

    @Test("Known frames need no read; an unknown frame reads once")
    func knownAndUnknownFrames() async {
        let tree = FakeFrameTree(["main", "a"])
        let registry = registry(tree)
        #expect(await registry.frame("a") == "a")
        #expect(await registry.frame("main") == "main")
        #expect(tree.reads == 1)
        #expect(await registry.frame("gone") == nil)
        #expect(tree.reads == 2)
        tree.ids.append("b")
        #expect(await registry.frame("b") == "b")
        #expect(tree.reads == 3)
        #expect(await registry.frame("b") == "b")
        #expect(tree.reads == 3)
    }

    @Test("A refresh or an invalidation reads the tree again")
    func refreshAndInvalidate() async {
        let tree = FakeFrameTree(["main"])
        let registry = registry(tree)
        #expect(await registry.frames() == ["main"])
        #expect(await registry.frames() == ["main"])
        #expect(tree.reads == 1)
        tree.ids = ["main", "x"]
        #expect(await registry.frames(refresh: true) == ["main", "x"])
        #expect(tree.reads == 2)
        tree.ids = ["main"]
        registry.invalidate()
        #expect(await registry.frame("x") == nil)
        #expect(tree.reads == 3)
    }
}
