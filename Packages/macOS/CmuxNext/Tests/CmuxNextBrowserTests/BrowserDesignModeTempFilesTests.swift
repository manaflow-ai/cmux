import Foundation
import Testing
@testable import CmuxNextBrowser

/// The files a design mode card becomes for the Home composer live under one root: each card's
/// folder goes once Home has its own copy, and the whole root goes at quit (and at the next launch,
/// after a crash).
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

    @Test func quitRemovesEverything() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = BrowserDesignModeTempFiles(root: root)
        _ = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: nil)
        _ = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: Data([1]))
        temp.removeAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aFolderOutsideTheRootIsLeftAlone() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("design-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        BrowserDesignModeTempFiles(root: root).remove(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
