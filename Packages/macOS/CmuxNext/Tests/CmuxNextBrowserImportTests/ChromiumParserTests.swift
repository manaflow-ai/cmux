import Foundation
import Testing
@testable import CmuxNextBrowserImport

@Suite struct ChromiumParserTests {
    @Test func bookmarksKeepFolderPathsAndSkipInternalPages() throws {
        let json = """
            {"checksum": "x", "version": 1, "roots": {
              "bookmark_bar": {"name": "Bookmarks bar", "type": "folder", "children": [
                {"type": "url", "name": "cmux", "url": "https://cmux.com/", "date_added": "13370000000000000"},
                {"type": "folder", "name": "Work", "children": [
                  {"type": "url", "name": "", "url": "https://github.com/manaflow-ai/cmux"},
                  {"type": "url", "name": "Settings", "url": "chrome://settings"}
                ]}
              ]},
              "other": {"name": "Other bookmarks", "type": "folder", "children": [
                {"type": "url", "name": "Docs", "url": "https://docs.example.com"}
              ]},
              "synced": {"name": "Mobile bookmarks", "type": "folder", "children": []}
            }}
            """
        let bookmarks = try ChromiumBookmarksParser().parse(Data(json.utf8))
        #expect(bookmarks.map(\.title) == ["cmux", "https://github.com/manaflow-ai/cmux", "Docs"])
        #expect(bookmarks[1].folderPath == ["Bookmarks bar", "Work"])
        #expect(bookmarks[2].folderPath == ["Other bookmarks"])
        // 13370000000000000 µs after 1601 = 2024-09-04T...Z
        let added = try #require(bookmarks[0].dateAdded)
        #expect(abs(added.timeIntervalSince1970 - (13_370_000_000 - 11_644_473_600)) < 1)
    }

    @Test func notBookmarksThrows() {
        #expect(throws: (any Error).self) { try ChromiumBookmarksParser().parse(Data("[]".utf8)) }
    }

    @Test func historyNewestFirstWithLimit() throws {
        let home = try FixtureHome()
        let file = home.url.appending(path: "History")
        let t = { (seconds: Int64) in BrowserTime().chromiumMicroseconds(Date(timeIntervalSince1970: TimeInterval(seconds))) }
        try FixtureHome.sqlite(file, [
            "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)",
            "INSERT INTO urls VALUES(1, 'https://old.example.com/', 'Old', 3, 0, \(t(1_000_000)), 0)",
            "INSERT INTO urls VALUES(2, 'https://new.example.com/', 'New', 7, 2, \(t(2_000_000)), 0)",
            "INSERT INTO urls VALUES(3, 'https://hidden.example.com/', 'Hidden', 1, 0, \(t(3_000_000)), 1)",
            "INSERT INTO urls VALUES(4, 'chrome://newtab/', 'New Tab', 9, 0, \(t(4_000_000)), 0)",
            "INSERT INTO urls VALUES(5, 'https://mid.example.com/', '', 1, 0, \(t(1_500_000)), 0)",
        ])
        let all = try ChromiumHistoryReader().read(file, limit: 10)
        #expect(all.map(\.url.host) == ["new.example.com", "mid.example.com", "old.example.com"])
        #expect(all[0].visitCount == 7)
        #expect(all[1].title == nil)
        #expect(abs(all[0].lastVisit.timeIntervalSince1970 - 2_000_000) < 1)
        #expect(try ChromiumHistoryReader().read(file, limit: 1).count == 1)
    }

    @Test func historyReadsWhileTheSourceIsLocked() throws {
        let home = try FixtureHome()
        let file = home.url.appending(path: "History")
        try FixtureHome.sqlite(file, [
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)",
            "INSERT INTO urls VALUES(1, 'https://a.example.com/', 'A', 1, 0, 13370000000000000, 0)",
        ])
        let before = try Data(contentsOf: file)
        #expect(try ChromiumHistoryReader().read(file, limit: 5).count == 1)
        #expect(try Data(contentsOf: file) == before, "the source database is never written")
    }

    @Test func sessionReplaysOpenTabsAtTheirSelectedNavigation() throws {
        var snss = SNSSWriter()
        snss.raw(0, 1, 10)            // tab 10 in window 1
        snss.raw(2, 10, 1)            // index 1
        snss.navigation(tab: 10, index: 0, url: "https://first.example.com/", title: "First")
        snss.navigation(tab: 10, index: 1, url: "https://second.example.com/", title: "Second ✓")
        snss.raw(7, 10, 0)            // tab 10 went back to navigation 0
        snss.raw(0, 1, 11)
        snss.raw(2, 11, 0)
        snss.raw(12, 11, 1)           // pinned
        snss.navigation(tab: 11, index: 0, url: "https://pinned.example.com/", title: "Pinned")
        snss.raw(0, 1, 12)
        snss.navigation(tab: 12, index: 0, url: "https://closed.example.com/", title: "Closed")
        snss.command(16, SNSSWriter.le32(12) + Data(count: 12))   // tab 12 closed
        snss.raw(0, 2, 13)
        snss.navigation(tab: 13, index: 0, url: "https://gone-window.example.com/", title: "Gone")
        snss.command(17, SNSSWriter.le32(2) + Data(count: 12))    // window 2 closed
        snss.raw(0, 3, 14)
        snss.navigation(tab: 14, index: 0, url: "chrome://newtab/", title: "New Tab")

        let tabs = ChromiumSessionReader().parse(snss.data)
        #expect(tabs.map(\.url.absoluteString) == ["https://pinned.example.com/", "https://first.example.com/"])
        #expect(tabs.map(\.pinned) == [true, false])
        #expect(tabs[1].title == "First")
    }

    @Test func sessionIgnoresEncryptedAndTruncatedFiles() {
        var encrypted = Data("SNSS".utf8) + SNSSWriter.le32(2)
        encrypted.append(contentsOf: [9, 0, 6, 1, 2, 3])
        #expect(ChromiumSessionReader().parse(encrypted).isEmpty)
        var snss = SNSSWriter()
        snss.navigation(tab: 1, index: 0, url: "https://a.example.com/", title: "A")
        #expect(ChromiumSessionReader().parse(snss.data.dropLast(3)).isEmpty)
        #expect(ChromiumSessionReader().parse(Data("junk".utf8)).isEmpty)
    }

    @Test func latestSessionFileByTimestamp() throws {
        let home = try FixtureHome()
        let sessions = home.url.appending(path: "Sessions")
        for name in ["Session_13370000000000000", "Session_13380000000000000", "Tabs_13390000000000000"] {
            try home.write("", to: sessions.appending(path: name))
        }
        #expect(ChromiumSessionReader().latestSessionFile(in: sessions)?.lastPathComponent == "Session_13380000000000000")
    }

    @Test func extensionsFromPreferencesAndManifests() throws {
        let home = try FixtureHome()
        let profile = home.url.appending(path: "Default")
        let ublock = String(repeating: "c", count: 32)
        let messages = String(repeating: "d", count: 32)
        let unpacked = String(repeating: "e", count: 32)
        let byDefault = String(repeating: "f", count: 32)
        let theme = String(repeating: "g", count: 32)
        try home.write(#"{"name": "uBlock Origin", "version": "1.60.0"}"#, to: profile.appending(path: "Extensions/\(ublock)/1.60.0_0/manifest.json"))
        try home.write(#"{"name": "uBlock Origin", "version": "1.9.0"}"#, to: profile.appending(path: "Extensions/\(ublock)/1.9.0_0/manifest.json"))
        try home.write(#"{"name": "__MSG_appName__", "default_locale": "en", "version": "2.0"}"#,
                       to: profile.appending(path: "Extensions/\(messages)/2.0_0/manifest.json"))
        try home.write(#"{"APPNAME": {"message": "Dark Reader"}}"#, to: profile.appending(path: "Extensions/\(messages)/2.0_0/_locales/en/messages.json"))
        try home.write(#"{"name": "Mine", "version": "0.1"}"#, to: profile.appending(path: "Extensions/\(unpacked)/0.1_0/manifest.json"))
        try home.write(#"{"name": "Bundled", "version": "1"}"#, to: profile.appending(path: "Extensions/\(byDefault)/1_0/manifest.json"))
        try home.write(#"{"name": "Dark Theme", "version": "1", "theme": {}}"#, to: profile.appending(path: "Extensions/\(theme)/1_0/manifest.json"))
        try home.write("""
            {"extensions": {"settings": {
              "\(ublock)": {"location": 1, "from_webstore": true, "state": 1},
              "\(messages)": {"location": 1, "from_webstore": true, "state": 0},
              "\(unpacked)": {"location": 4, "from_webstore": false},
              "\(byDefault)": {"location": 1, "from_webstore": true, "was_installed_by_default": true},
              "nmmhkkegccagdldgiimedpiccmgmieda": {"location": 10}
            }}}
            """, to: profile.appending(path: "Secure Preferences"))

        let extensions = ChromiumExtensionsReader().read(profile: profile)
        #expect(extensions.map(\.name) == ["Dark Reader", "uBlock Origin"])
        #expect(extensions[1].version == "1.60.0")
        #expect(extensions[0].enabled == false)
        #expect(extensions[1].webStoreURL.absoluteString == "https://chromewebstore.google.com/detail/\(ublock)")
    }
}
