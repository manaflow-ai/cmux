import Foundation
import Testing
@testable import CmuxNextFiles
import CmuxNextWakeups

/// Make Alias, symlinks, Delete Immediately, Compress / Expand, Get Info data,
/// the sidebar, Go menu places and Tab selection. All writes go to temp folders.
struct FileExtrasTests {
    @Test func aliasesAndSymlinksPointAtTheOriginal() async throws {
        let temp = try TempFolder()
        let report = try temp.file("report.txt", bytes: 3)
        let files = FileOperator()
        let links = try await files.makeLinks([report], kind: .symlink)
        #expect(links.map(\.lastPathComponent) == ["report.txt alias"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: links[0].path) == report.path)
        let aliases = try await files.makeLinks([report], kind: .alias)
        #expect(aliases.map(\.lastPathComponent) == ["report.txt alias 2"])
        #expect(try URL(resolvingAliasFileAt: aliases[0]).resolvingSymlinksInPath().path == report.path)
    }

    @Test func deleteImmediatelyRemovesWithoutTheTrash() async throws {
        let temp = try TempFolder()
        let doomed = try temp.file("doomed", bytes: 1)
        try temp.file("kept")
        try await FileOperator().deleteImmediately([doomed])
        #expect(temp.names() == ["kept"])
    }

    @Test func compressNamesLikeFinderAndExpandRoundTrips() async throws {
        let temp = try TempFolder()
        let a = try temp.file("a.txt", bytes: 10)
        let b = try temp.file("b.txt", bytes: 20)
        let files = FileOperator()
        let one = try await files.compress([a], archiveName: "Archive")
        #expect(one.lastPathComponent == "a.txt.zip")
        let both = try await files.compress([a, b], archiveName: "Archive")
        #expect(both.lastPathComponent == "Archive.zip")
        let again = try await files.compress([a, b], archiveName: "Archive")
        #expect(again.lastPathComponent == "Archive 2.zip")
        try await files.deleteImmediately([a])
        let single = try await files.expand(one)
        #expect(single.lastPathComponent == "a.txt")
        #expect(try Data(contentsOf: single).count == 10)
        let many = try await files.expand(both)
        #expect(many.lastPathComponent == "Archive")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: many.path)) == ["a.txt", "b.txt"])
    }

    @Test func getInfoReadsKindSizeAndFlags() async throws {
        let temp = try TempFolder()
        let file = try temp.file("data.bin", bytes: 4096)
        let reader = FileInfoReader()
        var info = try await reader.info(for: file)
        #expect(info.name == "data.bin")
        #expect(info.size == 4096)
        #expect(info.folder.path == temp.url.path)
        #expect(!info.isLocked)
        #expect(!info.kind.isEmpty)
        #expect(info.permissions & 0o600 == 0o600)
        try await reader.setLocked(true, for: file)
        info = try await reader.info(for: file)
        #expect(info.isLocked)
        try await reader.setLocked(false, for: file)
    }

    @Test func folderSizeCountsEveryItemInside() async throws {
        let temp = try TempFolder()
        try temp.folder("sub")
        try temp.file("a", bytes: 100)
        try temp.file("b", bytes: 50, in: "sub")
        let total = await FileInfoReader().folderSize(of: temp.url)
        #expect(total.bytes == 150)
        #expect(total.items == 3)
    }

    @Test func goMenuPlacesResolveFromHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(GoPlace.desktop.url(home: home).path == "/Users/me/Desktop")
        #expect(GoPlace.home.url(home: home).path == "/Users/me")
        #expect(GoPlace.applications.url(home: home).path == "/Applications")
        #expect(GoPlace.utilities.url(home: home).path == "/Applications/Utilities")
        #expect(GoPlace.iCloudDrive.url(home: home).path == "/Users/me/Library/Mobile Documents/com~apple~CloudDocs")
        #expect(GoPlace.place(forShiftCommandKey: "d") == .desktop)
        #expect(GoPlace.place(forShiftCommandKey: "z") == nil)
    }

    @MainActor
    @Test func sidebarKeepsUserFavoritesInOrder() throws {
        let defaults = try #require(UserDefaults(suiteName: "cmux-files-tests-\(UUID().uuidString)"))
        let home = URL(fileURLWithPath: "/Users/me")
        let volumes = [SidebarVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", isEjectable: false),
                       SidebarVolume(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB", isEjectable: true)]
        let sidebar = SidebarModel(home: home, defaults: defaults, volumes: { volumes })
        #expect(sidebar.favorites.map(\.path).prefix(2) == ["/Applications", "/Users/me/Desktop"])
        let project = URL(fileURLWithPath: "/Users/me/work/project")
        sidebar.addFavorite(project, at: 0)
        sidebar.addFavorite(project, at: 3) // already there: moves
        #expect(sidebar.favorites.firstIndex(of: project) == 3)
        sidebar.moveFavorite(from: 3, to: 0)
        #expect(sidebar.favorites.first == project)
        let again = SidebarModel(home: home, defaults: defaults, volumes: { volumes })
        #expect(again.favorites == sidebar.favorites)
        sidebar.removeFavorite(project)
        #expect(!SidebarModel(home: home, defaults: defaults, volumes: { volumes }).favorites.contains(project))
        #expect(sidebar.locations.map(\.name) == ["Macintosh HD", "USB"])
        #expect(sidebar.locations.filter(\.isEjectable).map(\.name) == ["USB"])
    }

    @MainActor
    @Test func tabSelectsTheNextNameAlphabeticallyInAnySortOrder() async throws {
        let temp = try TempFolder()
        try temp.file("b", bytes: 1)
        try temp.file("a", bytes: 3)
        try temp.file("c", bytes: 2)
        let model = FileBrowserModel(folder: temp.url, work: MainWorkScheduler(budget: MainFrameBudget()), sortOrder: FileSortOrder(field: .size), watcher: NeverWatcher())
        await model.reload()
        #expect(model.entries.map(\.name) == ["b", "c", "a"])
        model.selectAlphabetically(forward: true)
        #expect(model.selection == ["a"])
        model.selectAlphabetically(forward: true)
        #expect(model.selection == ["b"])
        model.selectAlphabetically(forward: false)
        #expect(model.selection == ["a"])
        model.selectAlphabetically(forward: false)
        #expect(model.selection == ["c"]) // wraps
    }

    @MainActor
    @Test func makeAliasAndCompressFromTheModelSelectTheResult() async throws {
        let temp = try TempFolder()
        try temp.file("x.txt", bytes: 5)
        let model = FileBrowserModel(folder: temp.url, work: MainWorkScheduler(budget: MainFrameBudget()), watcher: NeverWatcher())
        await model.reload()
        model.selection = ["x.txt"]
        await model.makeAliasesOfSelection(kind: .alias)
        #expect(model.selection == ["x.txt alias"])
        model.selection = ["x.txt"]
        await model.compressSelection(archiveName: "Archive")
        #expect(model.selection == ["x.txt.zip"])
        await model.undo()
        #expect(!temp.names().contains("x.txt.zip"))
        model.selection = ["x.txt alias"]
        await model.deleteSelectionImmediately()
        #expect(temp.names() == ["x.txt"])
        #expect(!model.canRedo)
    }
}
