import Foundation
import Testing
@testable import CmuxNextBrowserImport

@Suite struct OtherParserTests {
    @Test func firefoxBookmarksWithFoldersNotTags() throws {
        let home = try FixtureHome()
        let file = home.url.appending(path: "places.sqlite")
        try FixtureHome.sqlite(file, [
            "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_date INTEGER)",
            "CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, dateAdded INTEGER, guid TEXT)",
            "INSERT INTO moz_places VALUES(1, 'https://cmux.com/', 'cmux', 4, 0, 1700000000000000)",
            "INSERT INTO moz_places VALUES(2, 'https://mozilla.org/', 'Mozilla', 2, 0, 1600000000000000)",
            "INSERT INTO moz_places VALUES(3, 'place:sort=8', 'Recent', 0, 0, NULL)",
            "INSERT INTO moz_places VALUES(4, 'https://hidden.example.com/', 'H', 1, 1, 1800000000000000)",
            "INSERT INTO moz_bookmarks VALUES(1, 2, NULL, 0, 0, '', 0, 'root________')",
            "INSERT INTO moz_bookmarks VALUES(2, 2, NULL, 1, 0, 'toolbar', 0, 'toolbar_____')",
            "INSERT INTO moz_bookmarks VALUES(3, 2, NULL, 2, 0, 'Dev', 0, 'devfolder___')",
            "INSERT INTO moz_bookmarks VALUES(4, 1, 1, 3, 0, 'cmux home', 1700000000000000, 'b1__________')",
            "INSERT INTO moz_bookmarks VALUES(5, 1, 3, 2, 1, 'Recent', 0, 'b2__________')",
            "INSERT INTO moz_bookmarks VALUES(6, 2, NULL, 1, 1, 'tags', 0, 'tags________')",
            "INSERT INTO moz_bookmarks VALUES(7, 2, NULL, 6, 0, 'rust', 0, 'tagrust_____')",
            "INSERT INTO moz_bookmarks VALUES(8, 1, 2, 7, 0, NULL, 0, 'b3__________')",
            "INSERT INTO moz_bookmarks VALUES(9, 2, NULL, 1, 2, 'menu', 0, 'menu________')",
            "INSERT INTO moz_bookmarks VALUES(10, 1, 2, 9, 0, 'Mozilla', 0, 'b4__________')",
        ])
        let bookmarks = try FirefoxPlacesReader().readBookmarks(file)
        #expect(bookmarks.map(\.title).sorted() == ["Mozilla", "cmux home"])
        #expect(bookmarks.first { $0.title == "cmux home" }?.folderPath == ["Bookmarks Toolbar", "Dev"])
        #expect(bookmarks.first { $0.title == "Mozilla" }?.folderPath == ["Bookmarks Menu"])

        let history = try FirefoxPlacesReader().readHistory(file, limit: 10)
        #expect(history.map(\.url.host) == ["cmux.com", "mozilla.org"])
        #expect(abs(history[0].lastVisit.timeIntervalSince1970 - 1_700_000_000) < 1)
    }

    @Test func firefoxSessionStoreTabs() throws {
        let json = """
            {"windows": [
              {"tabs": [
                {"index": 2, "entries": [{"url": "https://a.example.com/", "title": "A"}, {"url": "https://b.example.com/", "title": "B"}]},
                {"index": 1, "pinned": true, "entries": [{"url": "about:preferences", "title": "Prefs"}]},
                {"index": 1, "pinned": true, "entries": [{"url": "https://mail.example.com/", "title": ""}]}
              ]},
              {"tabs": [{"index": 1, "entries": [{"url": "https://c.example.com/", "title": "C"}]}]}
            ], "_closedWindows": [{"tabs": [{"index": 1, "entries": [{"url": "https://closed.example.com/"}]}]}]}
            """
        let tabs = FirefoxSessionReader().parse(FixtureHome.mozLz4(json))
        #expect(tabs.map(\.url.host) == ["b.example.com", "mail.example.com", "c.example.com"])
        #expect(tabs.map(\.window) == [0, 0, 1])
        #expect(tabs[1].pinned && tabs[1].title == nil)
        #expect(FirefoxSessionReader().parse(Data("mozLz40\0junkjunk".utf8)).isEmpty)
    }

    @Test func safariBookmarksPlist() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "Title": "",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.com/", "URIDictionary": ["title": "Apple"]],
                    ["WebBookmarkType": "WebBookmarkTypeList", "Title": "News", "Children": [
                        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://news.example.com/", "URIDictionary": ["title": ""]],
                    ]],
                ]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://read.example.com/", "URIDictionary": ["title": "Later"]],
                ]],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let bookmarks = try SafariBookmarksParser().parse(data)
        #expect(bookmarks.map(\.title) == ["Apple", "https://news.example.com/", "Later"])
        #expect(bookmarks.map(\.folderPath) == [["Favorites"], ["Favorites", "News"], ["Reading List"]])
    }

    @Test func safariHistoryUsesLatestVisitTitle() throws {
        let home = try FixtureHome()
        let file = home.url.appending(path: "History.db")
        try FixtureHome.sqlite(file, [
            "CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER)",
            "CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)",
            "INSERT INTO history_items VALUES(1, 'https://apple.com/', 2)",
            "INSERT INTO history_items VALUES(2, 'https://webkit.org/', 1)",
            "INSERT INTO history_visits VALUES(1, 1, 700000000, 'Apple (old)')",
            "INSERT INTO history_visits VALUES(2, 1, 800000000, 'Apple')",
            "INSERT INTO history_visits VALUES(3, 2, 750000000, 'WebKit')",
        ])
        let history = try SafariHistoryReader().read(file, limit: 10)
        #expect(history.map(\.title) == ["Apple", "WebKit"])
        #expect(abs(history[0].lastVisit.timeIntervalSinceReferenceDate - 800_000_000) < 1)
    }
}
