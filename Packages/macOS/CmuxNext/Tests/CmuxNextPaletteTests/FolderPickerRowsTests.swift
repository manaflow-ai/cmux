@testable import CmuxNextPalette
import Foundation
import Testing

/// Row order and marking (R89), as the webviews reference picker
/// (webviews/src/viewer-empty/pickerModel.ts): recent first, folders
/// before files, git repos marked, hidden entries flagged, paging and
/// inline notices.
@Suite struct FolderPickerRowsTests {
    let start = URL(fileURLWithPath: "/w", isDirectory: true)

    func listing(_ entries: [FolderEntry], remaining: Int = 0, failure: FolderListingFailure? = nil) -> FolderListing {
        FolderListing(entries: entries, remaining: remaining, failure: failure)
    }

    @Test func folderModeOffersTheFolderFirstThenRecentFoldersFirst() {
        let rows = FolderPickerRows.make(
            state: FolderPickerState(mode: .folder, start: start),
            listing: listing([FolderEntry(name: "api", isDirectory: true, isGitRepository: true),
                              FolderEntry(name: "web", isDirectory: true)]),
            recents: ["/elsewhere/repo/", "/w/web/"])
        #expect(rows.map(\.id) == ["use", "dir:/w/web", "dir:/w/api"])
        #expect(rows.first { $0.id == "dir:/w/api" }?.isGitRepository == true)
        #expect(rows.first { $0.id == "dir:/w/web" }?.isRecent == true)
        #expect(rows.first { $0.id == "dir:/w/web" }?.isGitRepository == false)
    }

    @Test func aRecentFileMakesItsFolderRecentInAFilePicker() {
        let rows = FolderPickerRows.make(
            state: FolderPickerState(mode: .file(.markdown), start: start),
            listing: listing([FolderEntry(name: "api", isDirectory: true), FolderEntry(name: "docs", isDirectory: true),
                              FolderEntry(name: "A.md", isDirectory: false), FolderEntry(name: "README.md", isDirectory: false)]),
            recents: ["/w/docs/guide.md", "/w/README.md"])
        #expect(rows.map(\.id) == ["dir:/w/docs", "file:/w/README.md", "dir:/w/api", "file:/w/A.md"])
    }

    @Test func hiddenEntriesAreFlagged() {
        let rows = FolderPickerRows.make(state: FolderPickerState(mode: .file(.any), start: start),
                                         listing: listing([FolderEntry(name: "src", isDirectory: true),
                                                           FolderEntry(name: ".git", isDirectory: true),
                                                           FolderEntry(name: ".env", isDirectory: false)]),
                                         recents: [])
        #expect(rows.filter(\.isHidden).map(\.name) == [".git", ".env"])
    }

    @Test func aLargeFolderEndsInShowMore() {
        let rows = FolderPickerRows.make(state: FolderPickerState(mode: .folder, start: start),
                                         listing: listing([FolderEntry(name: "a", isDirectory: true)], remaining: 4_242), recents: [])
        #expect(rows.last?.kind == .more(4_242))
    }

    @Test func failuresAndEmptyFoldersSayWhyInline() {
        let denied = FolderPickerRows.make(state: FolderPickerState(mode: .folder, start: start),
                                           listing: listing([], failure: .permissionDenied), recents: [])
        #expect(denied.map(\.kind) == [.useFolder, .notice(.permissionDenied)])
        let missing = FolderPickerRows.make(state: FolderPickerState(mode: .file(.any), start: start),
                                            listing: listing([], failure: .notFound), recents: [])
        #expect(missing.map(\.kind) == [.notice(.notFound)])
        let onlyHidden = FolderPickerRows.make(state: FolderPickerState(mode: .file(.any), start: start),
                                               listing: listing([FolderEntry(name: ".DS_Store", isDirectory: false)]), recents: [])
        #expect(onlyHidden.last?.kind == .notice(.empty))
    }

    /// Recents are matched by path: nothing is read, so a recent inside
    /// Documents raises no prompt.
    @Test func recentsNeedNoFileSystem() {
        let set = FolderPickerRows.recentSet(["/Users/ada/Documents/proj/", "/Users/ada/Downloads/a.md"], mode: .file(.markdown))
        #expect(set == ["/Users/ada/Documents/proj", "/Users/ada/Downloads/a.md", "/Users/ada/Downloads"])
        #expect(FolderPickerRows.recentSet(["/r/a.md"], mode: .folder) == ["/r/a.md"])
    }

    @Test func listingHomeNeverLooksInsideGuardedFolders() {
        let home = "/Users/ada"
        for name in ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"] {
            #expect(!PickerPrivacy.mayProbe(home + "/" + name, home: home), "\(name)")
        }
        #expect(!PickerPrivacy.mayProbe("/Volumes/USB", home: home))
        #expect(PickerPrivacy.mayProbe(home + "/src", home: home))
        // Opened by the user: its children may be probed.
        #expect(PickerPrivacy.mayProbe(home + "/Documents/proj", home: home))
    }
}
