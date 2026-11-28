import Foundation
import Testing
@testable import CmuxNextBrowser

/// The files a design mode card becomes for the Home composer live under one root: each card's
/// folder goes once Home has its own copy. Quit and the next launch clean up leftovers.
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

    @Test func deferredLaunchCleanupLeavesCurrentCardsAlone() throws {
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        let temp = BrowserDesignModeTempFiles(root: root)
        let launch = Date().addingTimeInterval(-60)
        let leftover = temp.newFolder()
        _ = try BrowserDesignModeCardFiles(folder: leftover).write(card(), png: nil)
        let other = root.appendingPathComponent("other")
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        for folder in [leftover, other] {
            try manager.setAttributes([.creationDate: launch.addingTimeInterval(-60)], ofItemAtPath: folder.path)
        }
        let current = try BrowserDesignModeCardFiles(folder: temp.newFolder()).write(card(), png: Data([1]))
        temp.removeLeftovers(before: launch)
        #expect(!manager.fileExists(atPath: leftover.path))
        #expect(manager.fileExists(atPath: other.path))
        #expect(current.allSatisfy { manager.fileExists(atPath: $0.path) })
    }

    @Test func launchCleanupDoesNotFollowALinkAtTheRoot() throws {
        let manager = FileManager.default
        let outside = root.appendingPathExtension("outside")
        defer {
            try? manager.removeItem(at: root)
            try? manager.removeItem(at: outside)
        }
        let folder = BrowserDesignModeTempFiles(root: outside).newFolder()
        let files = try BrowserDesignModeCardFiles(folder: folder).write(card(), png: nil)
        try manager.createSymbolicLink(at: root, withDestinationURL: outside)
        BrowserDesignModeTempFiles(root: root).removeLeftovers(before: .distantFuture)
        #expect(files.allSatisfy { manager.fileExists(atPath: $0.path) })
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
