import Foundation
import Testing
@testable import CmuxNextFiles
import CmuxNextWakeups

/// Finder's Rename Items sheet: Replace Text, Add Text and Format, applied to the name stem.
struct BatchRenameTests {
    @Test func replaceTextKeepsTheExtension() {
        let rename = BatchRename(rule: .replace(find: "IMG", with: "Trip", caseSensitive: true))
        let plan = rename.plan(["IMG_1.jpg", "IMG_2.jpg", "notes.txt"], taken: [])
        #expect(plan.map(\.to) == ["Trip_1.jpg", "Trip_2.jpg", "notes.txt"])
        #expect(plan.allSatisfy { $0.problem == nil })
        #expect(plan.filter(\.changes).count == 2)
    }

    @Test func replaceCanIgnoreCase() {
        let rename = BatchRename(rule: .replace(find: "img", with: "x", caseSensitive: false))
        #expect(rename.plan(["IMG.png"], taken: []).map(\.to) == ["x.png"])
        let exact = BatchRename(rule: .replace(find: "img", with: "x", caseSensitive: true))
        #expect(exact.plan(["IMG.png"], taken: []).first?.changes == false)
    }

    @Test func addTextBeforeOrAfterTheName() {
        let after = BatchRename(rule: .add(text: " final", position: .afterName))
        #expect(after.plan(["a.txt", "b"], taken: []).map(\.to) == ["a final.txt", "b final"])
        let before = BatchRename(rule: .add(text: "2026 ", position: .beforeName))
        #expect(before.plan(["a.txt"], taken: []).map(\.to) == ["2026 a.txt"])
    }

    @Test func formatNumbersInOrderFromTheStart() {
        let index = BatchRename(rule: .format(base: "Trip", style: .index, position: .afterName, start: 7))
        #expect(index.plan(["z.jpg", "a.png"], taken: []).map(\.to) == ["Trip 7.jpg", "Trip 8.png"])
        let counter = BatchRename(rule: .format(base: "Trip", style: .counter, position: .afterName, start: 1))
        #expect(counter.plan(["x.jpg"], taken: []).map(\.to) == ["Trip 00001.jpg"])
        let first = BatchRename(rule: .format(base: "Trip", style: .index, position: .beforeName, start: 1))
        #expect(first.plan(["x.jpg"], taken: []).map(\.to) == ["1 Trip.jpg"])
    }

    @Test func formatWithDateUsesTheGivenClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09 08:53:20 UTC
        let rename = BatchRename(rule: .format(base: "Shot", style: .date, position: .afterName, start: 1),
                                 now: now, calendar: calendar)
        #expect(rename.plan(["a.png"], taken: []).map(\.to) == ["Shot 2025-10-09 at 08.53.20.png"])
    }

    @Test func problemsStopTheRename() {
        let rename = BatchRename(rule: .replace(find: "a", with: "b", caseSensitive: true))
        let plan = rename.plan(["a.txt", "c.txt"], taken: ["b.txt", "a.txt", "c.txt"])
        #expect(plan[0].problem == .exists)
        #expect(plan[1].problem == nil)
        let twice = BatchRename(rule: .format(base: "x", style: .date, position: .afterName, start: 1))
        let clash = twice.plan(["a.png", "b.png"], taken: [])
        #expect(clash[1].problem == .duplicate)
        let slash = BatchRename(rule: .replace(find: "a", with: "/", caseSensitive: true))
        #expect(slash.plan(["a"], taken: []).first?.problem == .invalid)
    }

    @Test func swappingNamesWithinTheSetIsAllowed() {
        // "a" -> "b" while "b" -> "c": "b" is free once its own item moves.
        let rename = BatchRename(rule: .format(base: "n", style: .index, position: .afterName, start: 1))
        let plan = rename.plan(["n 2", "n 1"], taken: ["n 1", "n 2"])
        #expect(plan.map(\.to) == ["n 1", "n 2"])
        #expect(plan.allSatisfy { $0.problem == nil })
    }

    @MainActor
    @Test func modelRenamesTheSelectionAndUndoes() async throws {
        let temp = try TempFolder()
        for name in ["IMG_1.jpg", "IMG_2.jpg", "keep.txt"] { try temp.file(name) }
        let model = FileBrowserModel(folder: temp.url, work: MainWorkScheduler(budget: MainFrameBudget()), watcher: NeverWatcher())
        await model.reload()
        model.selection = ["IMG_1.jpg", "IMG_2.jpg"]
        await model.batchRename(BatchRename(rule: .replace(find: "IMG", with: "Trip", caseSensitive: true)))
        #expect(model.lastError == nil)
        #expect(temp.names() == ["Trip_1.jpg", "Trip_2.jpg", "keep.txt"])
        #expect(model.selection == ["Trip_1.jpg", "Trip_2.jpg"])
        await model.undo()
        #expect(temp.names() == ["IMG_1.jpg", "IMG_2.jpg", "keep.txt"])
    }

    @MainActor
    @Test func modelRefusesAPlanWithProblems() async throws {
        let temp = try TempFolder()
        for name in ["a.txt", "b.txt"] { try temp.file(name) }
        let model = FileBrowserModel(folder: temp.url, work: MainWorkScheduler(budget: MainFrameBudget()), watcher: NeverWatcher())
        await model.reload()
        model.selection = ["a.txt"]
        await model.batchRename(BatchRename(rule: .replace(find: "a", with: "b", caseSensitive: true)))
        #expect(model.lastError != nil)
        #expect(temp.names() == ["a.txt", "b.txt"])
    }

    /// A Start at number whose later items do not fit in an `Int` is the error, not the name of
    /// the item that kept its old name ("b.txt" is a valid name).
    @MainActor
    @Test func modelSaysTheStartNumberIsTooLarge() async throws {
        let temp = try TempFolder()
        for name in ["a.txt", "b.txt"] { try temp.file(name) }
        let model = FileBrowserModel(folder: temp.url, work: MainWorkScheduler(budget: MainFrameBudget()), watcher: NeverWatcher())
        await model.reload()
        model.selection = ["a.txt", "b.txt"]
        await model.batchRename(BatchRename(rule: .format(base: "n", style: .counter, position: .afterName, start: .max)))
        #expect(model.lastError == .renameNumberTooLarge)
        #expect(temp.names() == ["a.txt", "b.txt"])
    }

    @MainActor
    @Test func modelSwapsNamesThroughATemporaryName() async throws {
        let temp = try TempFolder()
        try Data("one".utf8).write(to: temp.url.appendingPathComponent("n 2"))
        try Data("two".utf8).write(to: temp.url.appendingPathComponent("n 1"))
        let model = FileBrowserModel(folder: temp.url, work: MainWorkScheduler(budget: MainFrameBudget()), sortOrder: FileSortOrder(field: .size), watcher: NeverWatcher())
        await model.reload()
        model.selection = ["n 1", "n 2"]
        // Display order is by size (equal), then name: "n 1" (two) -> "n 2", "n 2" (one) -> "n 3".
        await model.batchRename(BatchRename(rule: .format(base: "n", style: .index, position: .afterName, start: 2)))
        #expect(model.lastError == nil)
        #expect(temp.names() == ["n 2", "n 3"])
        #expect(try String(contentsOf: temp.url.appendingPathComponent("n 2"), encoding: .utf8) == "two")
    }
}
