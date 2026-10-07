import Foundation
import SQLite3
import Testing
@testable import CmuxNextBrowserImport

/// One synthetic profile per engine-family reader, read the way the
/// bookmarks import reads it: detect the profile, then
/// `BrowserImporter.readBookmarks`. Never reads the real home.
@Suite struct BookmarkReaderTests {
    static let arcSidebar = """
        {"sidebar": {"containers": [{"global": {}}, {
          "topAppsContainerIDs": [{"default": true}, "top-default", {"custom": {"_0": {"directoryBasename": "Profile 1"}}}, "top-work"],
          "spaces": [
            "s1", {"id": "s1", "title": "Personal", "profile": {"default": true},
                   "containerIDs": ["unpinned", "s1-unpinned", "pinned", "s1-pinned"]},
            "s2", {"id": "s2", "title": "Work", "profile": {"custom": {"_0": {"directoryBasename": "Profile 1"}}},
                   "containerIDs": ["unpinned", "s2-unpinned", "pinned", "s2-pinned"]}
          ],
          "items": [
            "top-default", {"id": "top-default", "childrenIds": ["fav"], "data": {"itemContainer": {"containerType": {"topApps": {}}}}},
            "fav", {"id": "fav", "parentID": "top-default", "childrenIds": [], "title": null,
                    "data": {"tab": {"savedURL": "https://mail.example.com/", "savedTitle": "Mail"}}},
            "s1-pinned", {"id": "s1-pinned", "childrenIds": ["t1", "list"], "data": {"itemContainer": {}}},
            "t1", {"id": "t1", "parentID": "s1-pinned", "childrenIds": [], "title": "cmux", "createdAt": 700000000,
                   "data": {"tab": {"savedURL": "https://cmux.com/", "savedTitle": "cmux — terminal"}}},
            "list", {"id": "list", "parentID": "s1-pinned", "childrenIds": ["t2", "settings"], "title": "Reading", "data": {"list": {}}},
            "t2", {"id": "t2", "parentID": "list", "childrenIds": [], "title": null,
                   "data": {"tab": {"savedURL": "https://example.com/article", "savedTitle": "Article"}}},
            "settings", {"id": "settings", "parentID": "list", "childrenIds": [], "title": "Settings",
                   "data": {"tab": {"savedURL": "chrome://settings", "savedTitle": "Settings"}}},
            "s1-unpinned", {"id": "s1-unpinned", "childrenIds": ["open"], "data": {"itemContainer": {}}},
            "open", {"id": "open", "parentID": "s1-unpinned", "childrenIds": [], "title": "Open tab",
                     "data": {"tab": {"savedURL": "https://open.example.com/"}}},
            "top-work", {"id": "top-work", "childrenIds": [], "data": {"itemContainer": {}}},
            "s2-pinned", {"id": "s2-pinned", "childrenIds": ["w1"], "data": {"itemContainer": {}}},
            "w1", {"id": "w1", "parentID": "s2-pinned", "childrenIds": [], "title": "Tracker",
                   "data": {"tab": {"savedURL": "https://tracker.example.com/"}}}
          ]}]}}
        """

    @Test func arcSidebarKeepsSpacesFoldersAndFavoritesPerProfile() throws {
        let personal = try ArcSidebarReader().parse(Data(Self.arcSidebar.utf8), profileDirectory: "Default")
        #expect(personal.map(\.title) == ["Mail", "cmux", "Article"], "unpinned tabs and internal pages are skipped")
        #expect(personal.map(\.folderPath) == [["Favorites"], ["Personal"], ["Personal", "Reading"]])
        #expect(personal[1].dateAdded == Date(timeIntervalSinceReferenceDate: 700_000_000))
        let work = try ArcSidebarReader().parse(Data(Self.arcSidebar.utf8), profileDirectory: "Profile 1")
        #expect(work.map(\.url.host) == ["tracker.example.com"])
        #expect(work[0].folderPath == ["Work"])
        #expect(throws: (any Error).self) { try ArcSidebarReader().parse(Data("[]".utf8), profileDirectory: "Default") }
    }

    @Test func arcImportReadsTheSidebarOfTheDetectedProfile() throws {
        let home = try FixtureHome()
        let root = try home.chromium(.arc, profiles: [("Default", "Personal"), ("Profile 1", "Work")])
        try home.write(Self.arcSidebar, to: home.url.appending(path: try #require(ImportBrowser.arc.row?.sidebarFile)))
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.arc))
        #expect(root.lastPathComponent == "User Data")
        let work = try #require(source.profiles.first { $0.directoryName == "Profile 1" })
        #expect(work.availability(of: .bookmarks) == .available, "Arc has no Bookmarks file; the sidebar counts")
        #expect(try BrowserImporter.readBookmarks(work).map(\.title) == ["Tracker"])
    }

    @Test func chromiumProfileReadsItsBookmarksFile() throws {
        let home = try FixtureHome()
        let root = try home.chromium(.brave, profiles: [("Default", "Me")])
        try home.write(#"{"roots": {"bookmark_bar": {"name": "Bookmarks bar", "children": [{"type": "url", "name": "A", "url": "https://a.example/"}]}}}"#,
                       to: root.appending(path: "Default/Bookmarks"))
        let profile = try #require(BrowserSourceDetector(environment: home.environment).detect(.brave)?.profiles.first)
        let bookmarks = try BrowserImporter.readBookmarks(profile)
        #expect(bookmarks.map(\.title) == ["A"])
        #expect(bookmarks[0].folderPath == ["Bookmarks bar"])
    }

    @Test func firefoxReadsUncheckpointedWALFromACopy() throws {
        let home = try FixtureHome()
        let root = home.directory(.zen)
        try home.write("[Profile0]\nName=main\nIsRelative=1\nPath=Profiles/a.main\nDefault=1\n", to: root.appending(path: "profiles.ini"))
        let places = root.appending(path: "Profiles/a.main/places.sqlite")
        try FileManager.default.createDirectory(at: places.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A browser that is running: the bookmark sits only in the -wal file
        // while the source connection stays open.
        var db: OpaquePointer?
        #expect(sqlite3_open(places.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in [
            "PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0",
            "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT)",
            "CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT, dateAdded INTEGER)",
            "INSERT INTO moz_bookmarks VALUES(1, 2, NULL, 0, 0, '', 'root________', 0)",
            "INSERT INTO moz_bookmarks VALUES(2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____', 0)",
            "INSERT INTO moz_places VALUES(1, 'https://zen.example/')",
            "INSERT INTO moz_bookmarks VALUES(3, 1, 1, 2, 0, 'Zen', 'aaaaaaaaaaaa', 1700000000000000)",
        ] {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }
        #expect(FileManager.default.fileExists(atPath: places.path + "-wal"))
        let before = try Data(contentsOf: places)
        let profile = try #require(BrowserSourceDetector(environment: home.environment).detect(.zen)?.profiles.first)
        let bookmarks = try BrowserImporter.readBookmarks(profile)
        #expect(bookmarks.map(\.title) == ["Zen"])
        #expect(bookmarks[0].folderPath == ["Bookmarks Toolbar"])
        #expect(try Data(contentsOf: places) == before, "the source database is never written")
    }

    @Test func safariReadsBookmarksPlist() throws {
        let home = try FixtureHome()
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.example/", "URIDictionary": ["title": "Apple"]],
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try home.write(data, to: home.directory(.safari).appending(path: "Bookmarks.plist"))
        let profile = try #require(BrowserSourceDetector(environment: home.environment).detect(.safari)?.profiles.first)
        let bookmarks = try BrowserImporter.readBookmarks(profile)
        #expect(bookmarks.map(\.title) == ["Apple"])
        #expect(bookmarks[0].folderPath == ["Favorites"])
    }

    @Test func privateStoreReadsNothing() throws {
        let home = try FixtureHome()
        try FileManager.default.createDirectory(at: home.directory(.orion), withIntermediateDirectories: true)
        let profile = try #require(BrowserSourceDetector(environment: home.environment).detect(.orion)?.profiles.first)
        #expect(profile.availability(of: .bookmarks) == .unsupported(.exportFromSource), "the guided HTML export is the path")
        #expect(try BrowserImporter.readBookmarks(profile).isEmpty)
    }
}
