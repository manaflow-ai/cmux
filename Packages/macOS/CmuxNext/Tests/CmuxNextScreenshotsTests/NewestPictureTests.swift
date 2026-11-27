import CmuxNextScreenshots
import Foundation
import Testing

/// The newest picture in a folder (`pasteLastScreenshot`): read off the main actor through the
/// folder lister, pictures only, hidden files and subfolders skipped.
@Suite struct NewestPictureTests {
    @Test func picksTheNewestPictureAndSkipsOtherFiles() async throws {
        let folder = try TemporaryFolder()
        try folder.write("Screenshot old.png", modified: Date(timeIntervalSince1970: 100))
        let newest = try folder.write("Screenshot new.jpeg", modified: Date(timeIntervalSince1970: 300))
        try folder.write("notes.txt", modified: Date(timeIntervalSince1970: 900))
        try folder.write("Recording.mov", modified: Date(timeIntervalSince1970: 800))
        try folder.write(".Screenshot hidden.png", modified: Date(timeIntervalSince1970: 700))
        try folder.write("sub/deep.png", modified: Date(timeIntervalSince1970: 600))
        let found = await ScreenshotFolderReader().newestPicture(in: folder.url)
        #expect(found?.lastPathComponent == newest.lastPathComponent)
    }

    @Test func answersNilForAFolderWithoutPicturesOrNoFolder() async throws {
        let folder = try TemporaryFolder()
        try folder.write("notes.txt")
        #expect(await ScreenshotFolderReader().newestPicture(in: folder.url) == nil)
        #expect(await ScreenshotFolderReader().newestPicture(in: folder.url.appendingPathComponent("missing")) == nil)
    }
}
