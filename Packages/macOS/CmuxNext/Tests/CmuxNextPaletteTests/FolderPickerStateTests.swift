@testable import CmuxNextPalette
import Foundation
import Testing
import UniformTypeIdentifiers

/// The picker's pure navigation and filter rules (R89).
@Suite struct FolderPickerStateTests {
    let home = URL(fileURLWithPath: "/Users/ada", isDirectory: true)

    @Test func enterGoesDownAndUpSelectsTheFolderLeft() throws {
        let start = FolderPickerState(mode: .folder, start: URL(fileURLWithPath: "/Users/ada/src/"))
        #expect(start.directory.path == "/Users/ada/src")
        #expect(start.isAtStart)
        let inside = start.entering("cmux")
        #expect(inside.directory.path == "/Users/ada/src/cmux")
        #expect(!inside.isAtStart)
        let back = try #require(inside.up())
        #expect(back.directory.path == "/Users/ada/src")
        #expect(back.cameFrom == "cmux")
        #expect(back.isAtStart)
    }

    @Test func upStopsAtTheRoot() throws {
        let root = FolderPickerState(mode: .folder, start: URL(fileURLWithPath: "/"))
        #expect(root.isAtRoot)
        #expect(root.up() == nil)
        let usr = try #require(FolderPickerState(mode: .folder, start: URL(fileURLWithPath: "/usr")).up())
        #expect(usr.directory.path == "/")
    }

    @Test func crumbsAreEveryFolderUpToTheOneShown() {
        let crumbs = FolderPickerState(mode: .folder, start: home.appendingPathComponent("fun/cmux")).crumbs(home: home)
        #expect(crumbs.map(\.title) == ["~", "fun", "cmux"])
        #expect(crumbs.map(\.url.path) == ["/Users/ada", "/Users/ada/fun", "/Users/ada/fun/cmux"])
        let root = FolderPickerState(mode: .folder, start: URL(fileURLWithPath: "/usr/local")).crumbs(home: home)
        #expect(root.map(\.title) == ["/", "usr", "local"])
        #expect(root.map(\.url.path) == ["/", "/usr", "/usr/local"])
    }

    /// Typing filters, always: `~` alone is text. A path starts with `/` or
    /// `~/`, and `~/` means home only there.
    @Test func onlyAQueryStartingWithSlashOrTildeSlashIsAPath() throws {
        #expect(PickerPath("~", home: home) == nil)
        #expect(PickerPath("src", home: home) == nil)
        #expect(PickerPath("a/b", home: home) == nil)
        let homePath = try #require(PickerPath("~/", home: home))
        #expect(homePath.folder == home)
        #expect(homePath.segment.isEmpty)
        let typed = try #require(PickerPath("~/fun/cm", home: home))
        #expect(typed.typedFolder == "~/fun/")
        #expect(typed.segment == "cm")
        #expect(typed.folder.path == "/Users/ada/fun")
        #expect(try #require(PickerPath("/", home: home)).folder.path == "/")
        #expect(try #require(PickerPath("/usr/lo", home: home)).folder.path == "/usr")
    }

    @Test func aPathCompletesOneSegmentAtATime() throws {
        let path = try #require(PickerPath("~/fun/CM", home: home))
        let entries = [FolderEntry(name: "cmux", isDirectory: true), FolderEntry(name: "cmuxterm-hq", isDirectory: true),
                       FolderEntry(name: "chat", isDirectory: true), FolderEntry(name: "cm.md", isDirectory: false),
                       FolderEntry(name: ".cm", isDirectory: true)]
        let completions = path.completions(entries)
        #expect(completions.map(\.name) == ["cmux", "cmuxterm-hq", "cm.md"])
        #expect(path.completing(completions[0]) == "~/fun/cmux/")
        #expect(path.completing(completions[2]) == "~/fun/cm.md")
        #expect(try #require(PickerPath("~/fun/.c", home: home)).completions(entries).map(\.name) == [".cm"])
    }

    @Test func locationsComeInOrderEachFolderOnce() {
        let standard = PickerLocation.standard(home: home, iCloudDrive: true)
        #expect(standard.map(\.kind) == [.home, .desktop, .documents, .downloads, .iCloudDrive])
        #expect(standard.last?.url.path == "/Users/ada/Library/Mobile Documents/com~apple~CloudDocs")
        #expect(!PickerLocation.standard(home: home, iCloudDrive: false).contains { $0.kind == .iCloudDrive })
        let ordered = PickerLocation.ordered(workspace: [URL(fileURLWithPath: "/w/repo"), home],
                                             standard: standard, pinned: [URL(fileURLWithPath: "/p"), URL(fileURLWithPath: "/w/repo")])
        #expect(ordered.map(\.kind) == [.workspace, .workspace, .desktop, .documents, .downloads, .iCloudDrive, .pinned])
        #expect(ordered.map(\.url.path).first == "/w/repo")
    }

    @Test func breadcrumbShowsHomeAsTilde() {
        #expect(FolderPickerState(mode: .folder, start: home).breadcrumb(home: home) == "~")
        #expect(FolderPickerState(mode: .folder, start: home.appendingPathComponent("fun/cmux")).breadcrumb(home: home)
            == "~ \u{203A} fun \u{203A} cmux")
        #expect(FolderPickerState(mode: .folder, start: URL(fileURLWithPath: "/usr/local")).breadcrumb(home: home)
            == "/ \u{203A} usr \u{203A} local")
    }

    @Test func showMoreRaisesTheLimitAndAStepResetsIt() {
        let state = FolderPickerState(mode: .folder, start: home).showingMore()
        #expect(state.limit == 2 * FolderPickerState.pageSize)
        #expect(state.entering("x").limit == FolderPickerState.pageSize)
    }

    @Test func modesListTheRightFiles() {
        #expect(!PickerMode.folder.lists(file: "README.md"))
        #expect(PickerMode.file(.any).lists(file: "Makefile"))
        let markdown = PickerMode.file(.markdown)
        #expect(markdown.lists(file: "README.md"))
        #expect(markdown.lists(file: "notes.MARKDOWN"))
        #expect(!markdown.lists(file: "main.swift"))
        #expect(!markdown.lists(file: "md"))
        #expect(PickerMode(kind: .open(.files), filter: .markdown, showsAllFiles: true).lists(file: "main.swift"))
        #expect(!PickerMode(kind: .save, filter: .markdown).lists(file: "README.md"))
    }

    @Test func uniformTypesFilterByConformance() {
        let images = PickerFilter(types: [PickerFilter.FileType(.image)])
        #expect(images.accepts("photo.png"))
        #expect(images.accepts("photo.JPEG"))
        #expect(!images.accepts("notes.txt"))
        #expect(PickerMode(kind: .open(.files), filter: images).offersAllFiles)
        #expect(!PickerMode(kind: .open(.files), filter: PickerFilter(types: images.types, allowsAllFiles: false)).offersAllFiles)
        #expect(!PickerMode(kind: .open(.files)).offersAllFiles)
    }

    @Test func allFilesToggles() {
        let state = FolderPickerState(mode: .file(.markdown), start: home)
        #expect(state.togglingAllFiles().mode.lists(file: "a.swift"))
        #expect(!state.togglingAllFiles().togglingAllFiles().mode.lists(file: "a.swift"))
    }

    @Test func saveNamesKeepOrAddTheTypeExtension() {
        let text = PickerFilter(types: [PickerFilter.FileType(name: "Markdown", extensions: ["md", "markdown"]),
                                        PickerFilter.FileType(name: "Plain Text", extensions: ["txt"])])
        #expect(PickerSaveName.fileName("notes", filter: text, type: 0) == "notes.md")
        #expect(PickerSaveName.fileName("notes", filter: text, type: 1) == "notes.txt")
        #expect(PickerSaveName.fileName("notes.markdown", filter: text, type: 0) == "notes.markdown")
        #expect(PickerSaveName.fileName("  notes.txt ", filter: text, type: 0) == "notes.txt")
        #expect(PickerSaveName.fileName("notes", filter: .any, type: 0) == "notes")
        #expect(PickerSaveName.fileName("", filter: text, type: 0) == nil)
        #expect(PickerSaveName.fileName("..", filter: text, type: 0) == nil)
        #expect(PickerSaveName.fileName("a:b", filter: text, type: 0) == nil)
    }

    @Test func aTypedFolderPartNavigates() {
        let directory = URL(fileURLWithPath: "/Users/ada/src", isDirectory: true)
        #expect(PickerSaveName.split("notes.md") == (nil, "notes.md"))
        #expect(PickerSaveName.split("docs/notes.md") == ("docs/", "notes.md"))
        #expect(PickerSaveName.split("a/b/") == ("a/b/", ""))
        #expect(PickerSaveName.folder("docs/", from: directory, home: home).path == "/Users/ada/src/docs")
        #expect(PickerSaveName.folder("~/", from: directory, home: home) == home)
        #expect(PickerSaveName.folder("~/tmp/", from: directory, home: home).path == "/Users/ada/tmp")
        #expect(PickerSaveName.folder("/etc/", from: directory, home: home).path == "/etc")
    }

    @Test func thePrefilledNameSelectsAllButTheExtension() {
        #expect(PickerSaveName.selectionLength("notes.md") == 5)
        #expect(PickerSaveName.selectionLength("Makefile") == 8)
        #expect(PickerSaveName.selectionLength(".zshrc") == 6)
        #expect(PickerSaveName.selectionLength("archive.tar.gz") == 11)
    }

    @Test func protectedFoldersAreKnownWithoutTouchingThem() {
        #expect(PickerPrivacy.area(of: "/Users/ada/Documents", home: home.path) == .documents)
        #expect(PickerPrivacy.area(of: "/Users/ada/Documents/notes", home: home.path) == .documents)
        #expect(PickerPrivacy.area(of: "/Users/ada/Desktop", home: home.path) == .desktop)
        #expect(PickerPrivacy.area(of: "/Users/ada/Downloads", home: home.path) == .downloads)
        #expect(PickerPrivacy.area(of: "/Users/ada/Library/Mobile Documents/x", home: home.path) == .iCloudDrive)
        #expect(PickerPrivacy.area(of: "/Volumes/USB", home: home.path) == .volumes)
        #expect(PickerPrivacy.area(of: "/Volumes", home: home.path) == nil)
        #expect(PickerPrivacy.area(of: "/Users/ada/DocumentsOld", home: home.path) == nil)
        #expect(PickerPrivacy.area(of: "/Users/ada/src", home: home.path) == nil)
        #expect(PickerPrivacy.settingsURL(for: .documents).absoluteString.hasSuffix("Privacy_DocumentsFolder"))
    }
}
