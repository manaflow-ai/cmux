import Foundation
import Testing
@testable import CmuxNextBrowser

/// The files a design mode card becomes for the Home composer live under this launch's own root: each
/// card's folder goes once Home has its own copy, the whole root goes at quit, and the next launch
/// removes what earlier launches left without touching its own cards.
@Suite struct BrowserDesignModeTempFilesTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("design-temp-\(UUID().uuidString)")
    var files: BrowserDesignModeTempFiles { BrowserDesignModeTempFiles(base: base, launch: "this-launch") }

    func card() -> BrowserDesignModeCard {
        BrowserDesignModeCard(id: "d", name: "Design: p", text: "t", bounds: .zero, viewportWidth: 0)
    }

    @Test func aCardsFolderIsRemovedOnItsOwn() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let temp = files
        let first = temp.newFolder(), second = temp.newFolder()
        let kept = try BrowserDesignModeCardFiles(folder: second).write(card(), png: Data([1]))
        _ = try BrowserDesignModeCardFiles(folder: first).write(card(), png: nil)
        temp.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func quitRemovesOnlyThisLaunchsFiles() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let temp = files, other = BrowserDesignModeTempFiles(base: base, launch: "other-launch")
        let kept = try BrowserDesignModeCardFiles(folder: other.newFolder()).write(card(), png: nil)
        _ = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: nil)
        _ = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: Data([1]))
        temp.removeAll()
        #expect(!FileManager.default.fileExists(atPath: temp.root.path))
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// The launch cleanup runs on a files lane once the window is up, so a card this
    /// launch wrote before it runs must survive it.
    @Test func theLaunchCleanupRemovesEarlierLaunchesButNotThisLaunchsCards() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let earlier = BrowserDesignModeTempFiles(base: base, launch: "crashed-launch")
        let left = try BrowserDesignModeCardFiles(folder: earlier.newFolder()).write(card(), png: nil)
        // A card folder in the layout before per-launch folders: directly in the base.
        let oldLayout = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        _ = try BrowserDesignModeCardFiles(folder: oldLayout).write(card(), png: nil)
        let temp = files
        let attaching = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: Data([1]))
        temp.removeEarlierLaunches()
        #expect(attaching.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "the cleanup took this launch's card")
        #expect(!FileManager.default.fileExists(atPath: earlier.root.path))
        #expect(left.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: oldLayout.path))
    }

    @Test func theLaunchCleanupWithNoFilesDoesNothing() {
        files.removeEarlierLaunches()
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test func aFolderOutsideTheRootIsLeftAlone() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("design-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        files.remove(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
