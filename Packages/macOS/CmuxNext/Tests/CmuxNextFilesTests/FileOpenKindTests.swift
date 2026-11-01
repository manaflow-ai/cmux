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

    @Test func onlyAppsNeedTheUsersClick() {
        // An app runs code outside cmux: an agent's open never picks it. A web page renders in a
        // browser tab for an agent too (u18051), as any URL an agent opens does.
        #expect(!FileOpenKind.web.needsUserChoice)
        #expect(FileOpenKind.app.needsUserChoice)
        #expect(!FileOpenKind.preview.needsUserChoice)
        #expect(!FileOpenKind.editor.needsUserChoice)
    }

    /// u9489 (Oct 21): "right-click and open it as text instead of as the HTML page … in Monaco".
    /// A page cmux renders (Markdown, HTML, SVG) also opens as its source; other kinds already
    /// open as text or have none.
    @Test(arguments: [
        ("index.html", true), ("page.HTM", true), ("logo.svg", true), ("README.md", true), ("notes.markdown", true),
        ("notes.txt", false), ("main.swift", false), ("shot.png", false), ("spec.pdf", false), ("archive.zip", false),
    ])
    func renderedPagesAlsoOpenAsText(name: String, expected: Bool) {
        #expect(FileOpenKind(fileName: name, isDirectory: false, isPackage: false).opensAsText == expected)
    }

    @Test func foldersAndAppsHaveNoText() {
        #expect(!FileOpenKind(fileName: "site.html", isDirectory: true, isPackage: false).opensAsText)
        #expect(!FileOpenKind(fileName: "Xcode.app", isDirectory: true, isPackage: true).opensAsText)
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
