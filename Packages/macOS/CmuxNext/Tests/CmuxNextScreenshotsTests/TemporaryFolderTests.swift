import Foundation
import Testing

/// The fixture folder cleans up after itself: the source detector tests' `TemporaryItems` folder left
/// one `cmux-screenshots-tests-*` folder behind per test in each CI mini's `$TMPDIR`.
@Suite struct TemporaryFolderTests {
    @Test func aRunnerKeepsTheFoldersInItsJobTemp() {
        let root = TemporaryFolder.root(environment: ["RUNNER_TEMP": "/runner/_temp"])
        #expect(root.path == "/runner/_temp/cmux-screenshots-tests")
    }

    @Test func elsewhereTheFoldersAreUnderTMPDIR() {
        let expected = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-screenshots-tests").path
        #expect(TemporaryFolder.root(environment: [:]).path == expected)
        #expect(TemporaryFolder.root(environment: ["RUNNER_TEMP": ""]).path == expected)
    }

    /// `$TMPDIR/<entry>/TemporaryItems` is guarded by macOS: the folder is never a direct child.
    @Test func theFolderIsNeverADirectChildOfTheTempRoot() throws {
        let folder = try TemporaryFolder()
        #expect(folder.url.deletingLastPathComponent().lastPathComponent == "cmux-screenshots-tests")
    }

    @Test(.timeLimit(.minutes(1))) func aFolderWithTemporaryItemsIsRemovedWhenDropped() throws {
        var folder: TemporaryFolder? = try TemporaryFolder()
        let url = try #require(folder?.url)
        try folder?.folder("TemporaryItems")
        try folder?.write("TemporaryItems/NSIRD_screencaptureui_1/Screenshot.png")
        try folder?.write("Screenshot.png")
        folder = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
