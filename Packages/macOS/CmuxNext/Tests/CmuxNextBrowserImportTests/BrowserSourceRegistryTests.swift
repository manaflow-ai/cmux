import Foundation
import Testing
@testable import CmuxNextBrowserImport

/// The checked-in browser source registry (`browser-sources.json`) and its
/// rules: every row valid, every row discoverable in a fake home.
@Suite struct BrowserSourceRegistryTests {
    static let rows = BrowserSourceRegistry.shared.browsers.map(\.id)

    @Test func checkedInRegistryIsValid() {
        let registry = BrowserSourceRegistry.shared
        #expect(registry.browsers.count >= 32, "the registry resource did not load")
        #expect(registry.nonBrowsers.allSatisfy { !$0.kind.listsForBookmarks }, "browsers belong in `browsers`")
        #expect(registry.validationProblems() == [])
    }

    @Test func registryKeepsEveryBrowserEarlierBuildsStored() {
        // Ids stored by imports before the registry existed must stay rows.
        let stored: [ImportBrowser] = [
            .chrome, .chromeBeta, .chromeDev, .chromeCanary, .chromium, .arc, .dia, .brave, .braveBeta, .braveNightly,
            .edge, .edgeBeta, .edgeDev, .edgeCanary, .vivaldi, .opera, .operaGX, .helium, .comet, .sidekick, .yandex, .thorium,
            .safari, .safariTechnologyPreview, .firefox, .zen, .floorp, .librewolf, .waterfox, .tor, .orion, .duckDuckGo,
        ]
        for browser in stored { #expect(browser.row != nil, "\(browser) lost its row") }
    }

    @Test func validationFindsBadRows() throws {
        var registry = BrowserSourceRegistry.shared
        let chrome = try #require(registry.row("chrome"))
        var copy = chrome
        copy.id = "chromeCopy"
        copy.dataDirectories = ["Library/Application Support/Copy"]
        copy.safeStorage = SafeStorageItem(service: " ", confirmed: false)
        copy.evidence = [BrowserSourceEvidence(url: "http://example.com", note: "")]
        registry.browsers.append(copy)
        let problems = registry.validationProblems()
        #expect(problems.contains("chromeCopy: bundle id com.google.Chrome is in two rows"))
        #expect(problems.contains("chromeCopy: empty Safe Storage item"))
        #expect(problems.contains("chromeCopy: evidence needs an https URL and a note"))

        var shared = BrowserSourceRegistry.shared
        var twin = chrome
        twin.id = "twin"
        twin.bundleIDs = ["example.twin"]
        shared.browsers.append(twin)
        #expect(shared.validationProblems().contains("twin: data folder Library/Application Support/Google/Chrome is in two rows"))

        var outside = BrowserSourceRegistry.shared
        var escape = chrome
        escape.id = "escape"
        escape.bundleIDs = ["example.escape"]
        escape.dataDirectories = ["Documents/Browser"]
        outside.browsers.append(escape)
        #expect(outside.validationProblems().contains("escape: data folder Documents/Browser is not under ~/Library"))
    }

    @Test func newChromiumForkIsOneRow() throws {
        // A row is all a new Chromium fork needs: discovery, files and the
        // Keychain item come from the data.
        let json = """
            {"schemaVersion": 1,
             "engines": {"chromium": {"profiles": "chromiumLocalState", "bookmarks": "chromiumJSON",
                                      "files": {"bookmarks": "Bookmarks", "history": "History", "passwords": "Login Data"}},
                         "firefox": {"profiles": "firefoxProfilesIni", "bookmarks": "firefoxPlaces", "files": {"bookmarks": "places.sqlite"}},
                         "safari": {"profiles": "single", "bookmarks": "safariPlist", "files": {"bookmarks": "Bookmarks.plist"}},
                         "webkit": {"profiles": "single", "bookmarks": "none", "files": {}},
                         "other": {"profiles": "single", "bookmarks": "none", "files": {}}},
             "browsers": [{"id": "newFork", "name": "New Fork", "vendor": "Example", "kind": "browser", "engine": "chromium",
                           "bundleIDs": ["com.example.newfork"], "dataDirectories": ["Library/Application Support/NewFork"],
                           "safeStorage": {"service": "NewFork Safe Storage", "confirmed": false},
                           "evidence": [{"url": "https://example.com/newfork", "note": "test row"}]}]}
            """
        let registry = try BrowserSourceRegistry.decode(Data(json.utf8))
        #expect(registry.validationProblems() == [])
        let resolved = registry.resolved(try #require(registry.row("newFork")))
        #expect(resolved.profiles == .chromiumLocalState)
        #expect(resolved.bookmarks == .chromiumJSON)
        #expect(resolved.files.bookmarks == "Bookmarks")
    }

    @Test func unknownStoredIdIsNotDetected() throws {
        let home = try FixtureHome()
        let gone = ImportBrowser(rawValue: "goneBrowser")
        #expect(gone.displayName == "goneBrowser")
        #expect(gone.family == .other)
        #expect(BrowserSourceDetector(environment: home.environment).detect(gone) == nil)
        // Stored values decode and encode as the bare id.
        let data = try JSONEncoder().encode([ImportBrowser.chrome])
        #expect(String(decoding: data, as: UTF8.self) == #"["chrome"]"#)
        #expect(try JSONDecoder().decode([ImportBrowser].self, from: data) == [.chrome])
    }

    /// Discovery of every registry row in a fake home, by its own rule:
    /// the row's data folder, its profile list and its bookmarks file.
    @Test(arguments: rows)
    func everyRowIsDiscoveredInAFakeHome(_ id: String) throws {
        let browser = ImportBrowser(rawValue: id)
        let source = try #require(browser.source)
        let home = try FixtureHome()
        let root = home.url.appending(path: try #require(browser.dataDirectories.last), directoryHint: .isDirectory)
        var profileFolder = root
        switch source.profiles {
        case .chromiumLocalState:
            try home.write(#"{"profile": {"info_cache": {"Default": {"name": "Personal"}}}}"#, to: root.appending(path: "Local State"))
            profileFolder = root.appending(path: "Default", directoryHint: .isDirectory)
            try home.write("{}", to: profileFolder.appending(path: "Preferences"))
        case .firefoxProfilesIni:
            try home.write("[Profile0]\nName=main\nIsRelative=1\nPath=Profiles/a.main\nDefault=1\n", to: root.appending(path: "profiles.ini"))
            profileFolder = root.appending(path: "Profiles/a.main", directoryHint: .isDirectory)
            try home.write("// prefs", to: profileFolder.appending(path: "prefs.js"))
        case .dataDirectory, .single:
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        switch source.bookmarks {
        case .chromiumJSON:
            try home.write(#"{"roots": {}}"#, to: profileFolder.appending(path: try #require(source.files.bookmarks)))
        case .firefoxPlaces:
            try FixtureHome.sqlite(profileFolder.appending(path: try #require(source.files.bookmarks)), [
                "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT)",
                "CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT, dateAdded INTEGER)",
            ])
        case .safariPlist:
            let empty = try PropertyListSerialization.data(fromPropertyList: ["Children": [Any]()], format: .binary, options: 0)
            try home.write(empty, to: profileFolder.appending(path: try #require(source.files.bookmarks)))
        case .arcSidebar:
            try home.write(#"{"sidebar": {"containers": [{"global": {}}, {"items": [], "spaces": []}]}}"#,
                           to: home.url.appending(path: try #require(browser.row?.sidebarFile)))
        case .htmlExport, .noStore:
            break
        }
        let found = try #require(BrowserSourceDetector(environment: home.environment).detect(browser), "\(id) not detected")
        #expect(found.profiles.count == 1)
        let profile = try #require(found.profiles.first)
        switch (source.bookmarks, browser.family.isPrivateStore) {
        case (.chromiumJSON, _), (.firefoxPlaces, _), (.safariPlist, _), (.arcSidebar, _):
            #expect(profile.availability(of: .bookmarks) == .available, "\(id) bookmarks")
            #expect(throws: Never.self) { _ = try BrowserImporter.readBookmarks(profile) }
        case (.htmlExport, true):
            #expect(profile.availability(of: .bookmarks) == .unsupported(.exportFromSource), "\(id) bookmarks")
        case (.noStore, true):
            #expect(profile.availability(of: .bookmarks) == .unsupported(.unknownFormat), "\(id) bookmarks")
        case (.htmlExport, false), (.noStore, false):
            // An app with an in-app browser but no bookmarks (ChatGPT).
            #expect(profile.availability(of: .bookmarks) == .absent, "\(id) bookmarks")
        }
        if browser.family == .chromium, browser.safeStorageService == nil {
            #expect(profile.availability(of: .passwords) != .available, "\(id) has no known Keychain item")
        }
    }

    @Test func firstExistingDataFolderWins() throws {
        let home = try FixtureHome()
        let folders = ImportBrowser.safari.dataDirectories
        #expect(folders.count == 2)
        #expect(home.environment.dataDirectory(.safari).path.hasSuffix(folders[0]), "with nothing on disk, the first folder")
        try FileManager.default.createDirectory(at: home.url.appending(path: folders[1]), withIntermediateDirectories: true)
        #expect(home.environment.dataDirectory(.safari).path.hasSuffix(folders[1]), "the folder that exists")
    }

    @Test func registryMarksYandexPasswordsUnreadable() throws {
        let home = try FixtureHome()
        let root = try home.chromium(.yandex, profiles: [("Default", "Me")])
        try home.write("x", to: root.appending(path: "Default/Login Data"))
        try home.write("{}", to: root.appending(path: "Default/Bookmarks"))
        let profile = try #require(BrowserSourceDetector(environment: home.environment).detect(.yandex)?.profiles.first)
        #expect(profile.availability(of: .passwords) == .unsupported(.exportFromSource))
        #expect(!ImportBrowser.yandex.readsSavedPasswords)
        #expect(profile.availability(of: .bookmarks) == .available)
    }

    @Test func sharedProfileFolderIsListedOnce() throws {
        // Two rows that point at one folder list its profiles once.
        let home = try FixtureHome()
        let root = try home.chromium(.chrome, profiles: [("Default", "Personal")])
        try home.write("{}", to: root.appending(path: "Default/Bookmarks"))
        let sources = BrowserSourceDetector(environment: home.environment).detect([.chrome, .chrome])
        #expect(sources.map(\.browser) == [.chrome])
    }

    @Test func unverifiedRowIsFoundByAppName() throws {
        let row = try #require(BrowserSourceRegistry.shared.browsers.first { $0.verified == false && $0.bundleIDs.isEmpty && $0.engine == .chromium })
        let browser = ImportBrowser(rawValue: row.id)
        let home = try FixtureHome()
        let root = home.url.appending(path: try #require(row.dataDirectories.first))
        try home.write(#"{"profile": {"info_cache": {"Default": {"name": "Me"}}}}"#, to: root.appending(path: "Local State"))
        try home.write("{}", to: root.appending(path: "Default/Preferences"))
        let app = URL(fileURLWithPath: "/Applications/\(row.name).app")
        let environment = ImportEnvironment(homeDirectory: home.url, locateApp: { _ in nil },
                                            locateAppNamed: { $0 == row.appNames?.first ? app : nil })
        let source = try #require(BrowserSourceDetector(environment: environment).detect(browser))
        #expect(source.appURL == app)
    }
}
