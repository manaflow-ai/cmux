import Foundation
import Testing
@testable import CmuxNextFiles

/// How cmux shows a file a person clicks (plans/cmux-next/files-finder-parity-DESIGN.md, 1).
struct FileOpenKindTests {
    @Test(arguments: [
        ("index.html", FileOpenKind.web), ("page.HTM", .web), ("doc.xhtml", .web), ("logo.svg", .web),
        ("shot.png", .preview), ("photo.JPEG", .preview), ("anim.gif", .preview), ("spec.pdf", .preview),
        ("clip.mp4", .preview), ("song.mp3", .preview),
        ("README.md", .markdown), ("notes.markdown", .markdown),
        ("main.swift", .editor), ("App.tsx", .editor), ("data.json", .editor), ("Makefile", .editor),
        ("notes.txt", .editor), ("run.sh", .editor),
        ("report.docx", .other), ("archive.zip", .other), ("disk.dmg", .other),
    ])
    func classifiesFilesByName(name: String, expected: FileOpenKind) {
        #expect(FileOpenKind(fileName: name, isDirectory: false, isPackage: false) == expected)
    }

    @Test func folderOpensInFiles() {
        #expect(FileOpenKind(fileName: "src", isDirectory: true, isPackage: false) == .folder)
        // A folder with a dot in its name is still a folder.
        #expect(FileOpenKind(fileName: "v1.2", isDirectory: true, isPackage: false) == .folder)
    }

    @Test func appsAndPackagesGoToTheSystem() {
        #expect(FileOpenKind(fileName: "Xcode.app", isDirectory: true, isPackage: true) == .app)
        #expect(FileOpenKind(fileName: "Thing.app", isDirectory: true, isPackage: false) == .app)
        #expect(FileOpenKind(fileName: "Library.photoslibrary", isDirectory: true, isPackage: true) == .app)
    }

    @Test func onlyWebAndOtherNeedTheUsersClick() {
        // A page runs script and `.other` leaves cmux: an agent's open never picks them.
        #expect(FileOpenKind.web.needsUserChoice)
        #expect(FileOpenKind.app.needsUserChoice)
        #expect(!FileOpenKind.preview.needsUserChoice)
        #expect(!FileOpenKind.editor.needsUserChoice)
    }

    @Test func classifiesAURLOnDisk() throws {
        let temp = try TempFolder()
        let page = try temp.file("index.html", bytes: 3)
        let folder = try temp.folder("site")
        #expect(FileOpenKind(url: page) == .web)
        #expect(FileOpenKind(url: folder) == .folder)
        #expect(FileOpenKind(url: temp.url.appendingPathComponent("missing.html")) == nil)
    }
}
