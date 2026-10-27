import Foundation
import Testing
@testable import CmuxNextBrowser

/// The files a design mode card becomes for the Home composer live in this launch's folder under one root:
/// each card's folder goes once Home has its own copy, this launch's folder goes at quit, and the launch
/// cleanup (posted after startup) takes what earlier launches left after a crash, never this launch's cards.
@Suite struct BrowserDesignModeTempFilesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("design-temp-\(UUID().uuidString)")

    func card() -> BrowserDesignModeCard {
        BrowserDesignModeCard(id: "d", name: "Design: p", text: "t", bounds: .zero, viewportWidth: 0)
    }

    @Test func aCardsFolderIsRemovedOnItsOwn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = BrowserDesignModeTempFiles(root: root)
        let first = temp.newFolder(), second = temp.newFolder()
        let kept = try BrowserDesignModeCardFiles(folder: second).write(card(), png: Data([1]))
        _ = try BrowserDesignModeCardFiles(folder: first).write(card(), png: nil)
        temp.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func quitRemovesEveryCardOfThisLaunch() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = BrowserDesignModeTempFiles(root: root)
        _ = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: nil)
        _ = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: Data([1]))
        temp.removeAll()
        #expect(!FileManager.default.fileExists(atPath: temp.run.path))
    }

    @Test func theLaunchCleanupTakesEarlierLaunchesFilesAndKeepsThisLaunchsCards() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let crashed = BrowserDesignModeTempFiles(root: root, run: "earlier-launch")
        let leftover = try BrowserDesignModeCardFiles(folder: crashed.newFolder()).write(card(), png: nil)
        // A card folder right in the root, as launches before the per-launch folders wrote them.
        let flat = try BrowserDesignModeCardFiles(folder: root.appendingPathComponent(UUID().uuidString, isDirectory: true))
            .write(card(), png: nil)
        let temp = BrowserDesignModeTempFiles(root: root)
        let mine = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: Data([1]))
        temp.removeEarlierRuns()
        #expect((leftover + flat).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: crashed.run.path))
        #expect(mine.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func theLaunchCleanupWithNoRootDoesNothing() {
        BrowserDesignModeTempFiles(root: root).removeEarlierRuns()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aFolderOutsideThisLaunchsFolderIsLeftAlone() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("design-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        BrowserDesignModeTempFiles(root: root).remove(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
