@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// The launch restore notice (R96 quit hook): a draft whose file changed on
/// disk after the state its edits are based on says so in the toast.
@MainActor
struct RecoveryNoticeTests {
    @Test func anOutsideChangeDuringTheDebounceIsFlaggedAtLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let base = RecoveryDraftBase(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.int64Value)
        let clock = ManualClock()
        let store = RecoveryDraftStore(directory: directory.appendingPathComponent("recovery"), clock: clock)
        store.update(id: "file:local:\(file.path)", title: "notes.md", contents: Data("draft".utf8), filePath: file.path, base: base)
        // The outside change lands inside the 1 s debounce, before the draft is written.
        try "version two".write(to: file, atomically: true, encoding: .utf8)
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .seconds(1))
        var drafts = await store.drafts()
        for _ in 0..<500 where drafts.isEmpty {
            await Task.yield()
            drafts = await store.drafts()
        }
        let draft = try #require(drafts.first)
        #expect(await RecoveryNotice.message(for: draft, store: store) == QuitStrings.recoveredChanged("notes.md"))
    }
}
