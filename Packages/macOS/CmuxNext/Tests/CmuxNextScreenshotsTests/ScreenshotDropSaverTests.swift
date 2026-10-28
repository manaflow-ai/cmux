import AppKit
import CmuxNextFileGrid
import CmuxNextFiles
import CmuxNextScreenshots
import Foundation
import Testing
import CmuxNextWakeups

/// Drops into the pane are saved through CmuxNextFiles: files are copied (never moved) under
/// Finder's Keep Both name, picture data becomes a time-named PNG.
@MainActor @Suite struct ScreenshotDropSaverTests {
    @Test func aDroppedFileIsCopiedInUnderAFreeName() async throws {
        let source = try TemporaryFolder()
        let target = try TemporaryFolder()
        let file = try source.write("Shot.png")
        try target.write("Shot.png")
        let drop = Drop(droppedFileURLs: [file])
        let saver = ScreenshotDropSaver(files: FileOperator(work: BackgroundWork()))
        #expect(saver.canSave(drop))
        #expect(!saver.canSave(Drop()))
        let saved = try await saver.save(drop, into: target.url)
        #expect(saved.map(\.lastPathComponent) == ["Shot 2.png"])
        #expect(FileManager.default.fileExists(atPath: file.path), "a drop copies, never moves")
    }

    /// A file dropped from the pane's own folder is not copied onto itself.
    @Test func aFileFromTheSameFolderIsNotCopiedAgain() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("Shot.png")
        let saved = try await ScreenshotDropSaver(files: FileOperator(work: BackgroundWork())).save(Drop(droppedFileURLs: [file]), into: folder.url)
        #expect(saved.isEmpty)
    }

    @Test func droppedPictureDataBecomesATimeNamedPNG() async throws {
        let target = try TemporaryFolder()
        let image = NSImage(size: CGSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try target.write(ScreenshotDropSaver.droppedName(at: date))
        let saver = ScreenshotDropSaver(files: FileOperator(work: BackgroundWork()), now: { date })
        let saved = try await saver.save(Drop(droppedImage: image), into: target.url)
        let name = ScreenshotDropSaver.droppedName(at: date)
        let numbered = (name as NSString).deletingPathExtension + " 2.png"
        #expect(saved.map(\.lastPathComponent) == [numbered])
        let data = try Data(contentsOf: try #require(saved.first))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "a PNG")
    }
}
