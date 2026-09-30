import Foundation
import Testing
@testable import CmuxFileTree

@Suite struct FileTreeViewStateRepositoryTests {
    private func makeDefaults(suite: String = "cmux-file-tree-state-\(UUID().uuidString)") -> UserDefaults {
        UserDefaults(suiteName: suite)!
    }

    @Test func statesSurviveANewRepositoryInstance() async {
        let suite = "cmux-file-tree-state-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let state = FileTreeViewState(
            expandedPaths: ["src", "src/app"],
            selectedPaths: ["src/app/main.swift"],
            anchorPath: "src/app/main.swift",
            topVisiblePath: "src",
            topVisibleOffset: 4
        )
        await FileTreeViewStateRepository(defaults: makeDefaults(suite: suite)).save(state, for: "ws|local:/p")
        let restored = await FileTreeViewStateRepository(defaults: makeDefaults(suite: suite)).state(for: "ws|local:/p")
        #expect(restored == state)
    }

    @Test func leastRecentlyUsedScopesAreEvicted() async {
        let repository = FileTreeViewStateRepository(defaults: makeDefaults(), capacity: 2)
        await repository.save(FileTreeViewState(expandedPaths: ["a"]), for: "one")
        await repository.save(FileTreeViewState(expandedPaths: ["b"]), for: "two")
        await repository.save(FileTreeViewState(expandedPaths: ["a", "c"]), for: "one")
        await repository.save(FileTreeViewState(expandedPaths: ["d"]), for: "three")
        #expect(await repository.state(for: "two") == nil)
        #expect(await repository.state(for: "one")?.expandedPaths == ["a", "c"])
        #expect(await repository.state(for: "three") != nil)
    }

    @Test func pathListsAreCapped() async {
        let repository = FileTreeViewStateRepository(defaults: makeDefaults(), maxPathsPerState: 3)
        await repository.save(FileTreeViewState(expandedPaths: (0..<10).map { "d\($0)" }), for: "s")
        #expect(await repository.state(for: "s")?.expandedPaths.count == 3)
    }

    @Test func relativePathsRoundTrip() {
        #expect(FileTreeViewState.relativePath("/p/src/a", root: "/p") == "src/a")
        #expect(FileTreeViewState.relativePath("/p", root: "/p") == "")
        #expect(FileTreeViewState.relativePath("/other", root: "/p") == nil)
        #expect(FileTreeViewState.relativePath("/pp/x", root: "/p") == nil)
        #expect(FileTreeViewState.absolutePath("src/a", root: "/p") == "/p/src/a")
        #expect(FileTreeViewState.absolutePath("etc", root: "/") == "/etc")
        #expect(FileTreeViewState.relativePath("/etc", root: "/") == "etc")
    }
}
