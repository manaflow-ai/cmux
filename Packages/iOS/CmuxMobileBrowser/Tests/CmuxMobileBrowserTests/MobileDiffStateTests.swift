import Testing
@testable import CmuxMobileBrowser
import CmuxMobileShellModel

@MainActor
@Suite struct MobileDiffStateTests {
    @Test func nativeSelectionMovesThroughStableFileIDs() {
        let state = MobileDiffState()
        state.load(MobileDiffDocument(
            patch: "diff --git a/a b/a",
            repositoryRoot: "/repo",
            title: "Changes"
        ))
        state.updateFiles([
            MobileDiffFile(id: "a", path: "Sources/A.swift", added: 2, deleted: 1),
            MobileDiffFile(id: "b", path: "Sources/B.swift", added: 4, deleted: 0),
        ], selectedFileID: "a")

        #expect(state.selectedFileID == "a")
        #expect(!state.canSelectPrevious)
        #expect(state.canSelectNext)
        state.selectNext()
        #expect(state.selectedFileID == "b")
        #expect(state.canSelectPrevious)
        #expect(!state.canSelectNext)
        state.selectPrevious()
        #expect(state.selectedFileID == "a")
    }

    @Test func refreshedFilesRepairAStaleSelection() {
        let state = MobileDiffState()
        state.updateFiles([
            MobileDiffFile(id: "a", path: "A.swift", added: 1, deleted: 0),
        ], selectedFileID: "missing")

        #expect(state.selectedFileID == "a")
    }

    @Test func staleRendererSelectionDoesNotOverrideNativeNavigation() {
        let state = MobileDiffState()
        let files = [
            MobileDiffFile(id: "a", path: "A.swift", added: 1, deleted: 0),
            MobileDiffFile(id: "b", path: "B.swift", added: 1, deleted: 0),
        ]
        state.updateFiles(files, selectedFileID: "a")
        state.selectFile(id: "b")

        state.updateFiles(files, selectedFileID: "a")

        #expect(state.selectedFileID == "b")
    }
}
