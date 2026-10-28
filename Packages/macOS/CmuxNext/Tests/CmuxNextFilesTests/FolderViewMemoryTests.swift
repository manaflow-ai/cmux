import Foundation
import Testing
@testable import CmuxNextFiles
import CmuxNextWakeups

/// Finder keeps each folder's view and order; Files keeps them in defaults.
@MainActor
struct FolderViewMemoryTests {
    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "cmux-files-tests-\(UUID().uuidString)"))
    }

    @Test func foldersComeBackInTheirOwnViewAndOrder() async throws {
        let temp = try TempFolder()
        let a = try temp.folder("a"), b = try temp.folder("b")
        let defaults = try scratchDefaults()
        let model = FileBrowserModel(folder: a, work: MainWorkScheduler(budget: MainFrameBudget()), watcher: NeverWatcher(), memory: FolderViewMemory(defaults: defaults))
        await model.reload()
        model.viewMode = .icons
        model.sortOrder = FileSortOrder(field: .size)
        await model.open(b)
        #expect(model.viewMode == .icons, "a folder with no memory keeps the current view")
        model.viewMode = .columns
        await model.goBack()
        #expect(model.viewMode == .icons)
        #expect(model.sortOrder.field == .size)
        let fresh = FileBrowserModel(folder: b, work: MainWorkScheduler(budget: MainFrameBudget()), watcher: NeverWatcher(), memory: FolderViewMemory(defaults: defaults))
        #expect(fresh.viewMode == .columns)
        #expect(fresh.sortOrder.field == .size)
    }

    @Test func memoryKeepsOnlyTheNewestFolders() throws {
        let memory = FolderViewMemory(defaults: try scratchDefaults(), capacity: 2)
        let prefs = FolderViewMemory.Prefs(viewMode: .icons, sortOrder: FileSortOrder())
        for name in ["/one", "/two", "/three"] { memory.remember(prefs, for: URL(fileURLWithPath: name)) }
        #expect(memory.prefs(for: URL(fileURLWithPath: "/one")) == nil)
        #expect(memory.prefs(for: URL(fileURLWithPath: "/three")) == prefs)
    }

    @Test func statusLineKnowsTheFreeSpace() async {
        let folder = URL(fileURLWithPath: "/Volumes/Work")
        let reader = FileInfoReader { _ in (important: 7_000, plain: 5_000) }
        #expect(await reader.availableCapacity(of: folder) == 7_000)
    }

    /// Some volumes report 0 for important use (CI's ephemeral disks do); the plain figure is the answer then.
    @Test func aZeroForImportantUseFallsBackToThePlainFigure() async {
        let reader = FileInfoReader { _ in (important: 0, plain: 5_000) }
        #expect(await reader.availableCapacity(of: URL(fileURLWithPath: "/Volumes/Work")) == 5_000)
    }

    /// A volume that reports 0 free is an unknown, so the status line leaves "available" out
    /// instead of saying "Zero KB available".
    @Test func aVolumeThatReportsNothingFreeIsUnknown() async {
        let reader = FileInfoReader { _ in (important: 0, plain: 0) }
        #expect(await reader.availableCapacity(of: URL(fileURLWithPath: "/Volumes/Work")) == nil)
        let silent = FileInfoReader { _ in (important: nil, plain: nil) }
        #expect(await silent.availableCapacity(of: URL(fileURLWithPath: "/Volumes/Work")) == nil)
    }
}
