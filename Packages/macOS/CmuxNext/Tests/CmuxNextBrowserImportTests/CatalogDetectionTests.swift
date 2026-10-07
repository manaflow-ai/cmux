import Foundation
import Testing
@testable import CmuxNextBrowserImport

/// Detection of every browser in the catalog from fixture folders, one
/// family at a time. Never reads the real home.
@Suite struct CatalogDetectionTests {
    static let chromiumBrowsers = ImportBrowser.allCases.filter {
        $0.family == .chromium && !$0.profileIsDataDirectory && $0.safeStorageService != nil
    }
    static let firefoxBrowsers = ImportBrowser.allCases.filter { $0.family == .firefox && $0 != .tor }

    @Test func catalogKeepsTheUsersList() {
        // The user's list (2026-09-30); the registry may only grow.
        let expected: Set<ImportBrowser> = [
            .chrome, .chromeBeta, .chromeDev, .chromeCanary, .chromium, .arc, .dia, .brave, .braveBeta, .braveNightly,
            .edge, .edgeBeta, .edgeDev, .edgeCanary, .vivaldi, .opera, .operaGX, .helium, .comet, .sidekick, .yandex, .thorium,
            .safari, .safariTechnologyPreview, .firefox, .zen, .floorp, .librewolf, .waterfox, .tor, .orion, .duckDuckGo,
        ]
        #expect(Set(ImportBrowser.allCases).isSuperset(of: expected))
    }

    @Test(arguments: chromiumBrowsers)
    func chromiumFamily(_ browser: ImportBrowser) throws {
        let home = try FixtureHome()
        let root = try home.chromium(browser, profiles: [("Default", "Personal"), ("Profile 1", "Work")])
        try FixtureHome.sqlite(root.appending(path: "Default/Network/Cookies"), ["CREATE TABLE cookies(x)"])
        try FixtureHome.sqlite(root.appending(path: "Profile 1/Cookies"), ["CREATE TABLE cookies(x)"])
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(browser))
        #expect(source.profiles.map(\.id) == ["\(browser.rawValue)/Default", "\(browser.rawValue)/Profile 1"])
        // Both cookie locations count (Network/Cookies since Chromium 96).
        #expect(source.profiles.allSatisfy { $0.availability(of: .cookies) == .available })
    }

    @Test(arguments: ImportBrowser.allCases.filter(\.profileIsDataDirectory))
    func operaKeepsOneProfileInItsDataFolder(_ browser: ImportBrowser) throws {
        let home = try FixtureHome()
        let root = home.directory(browser)
        try home.write("{}", to: root.appending(path: "Bookmarks"))
        try FixtureHome.sqlite(root.appending(path: "Network/Cookies"), ["CREATE TABLE cookies(x)"])
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(browser))
        #expect(source.profiles.count == 1)
        #expect(source.profiles[0].path.standardizedFileURL == root.standardizedFileURL)
        #expect(source.profiles[0].importableKinds == [.bookmarks, .cookies])
    }

    @Test(arguments: firefoxBrowsers)
    func firefoxFamily(_ browser: ImportBrowser) throws {
        let home = try FixtureHome()
        let root = home.directory(browser)
        try home.write("[Profile0]\nName=main\nIsRelative=1\nPath=Profiles/a.main\nDefault=1\n", to: root.appending(path: "profiles.ini"))
        try FixtureHome.sqlite(root.appending(path: "Profiles/a.main/places.sqlite"), ["CREATE TABLE t(x)"])
        try FixtureHome.sqlite(root.appending(path: "Profiles/a.main/cookies.sqlite"), ["CREATE TABLE moz_cookies(x)"])
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(browser))
        #expect(source.profiles.map(\.displayName) == ["main"])
        #expect(source.profiles[0].importableKinds == [.bookmarks, .history, .cookies])
    }

    @Test func torRefusesCookiesAndHistory() throws {
        let home = try FixtureHome()
        let profile = home.directory(.tor).appending(path: "profile.default")
        try home.write("// prefs", to: profile.appending(path: "prefs.js"))
        try FixtureHome.sqlite(profile.appending(path: "places.sqlite"), ["CREATE TABLE t(x)"])
        try FixtureHome.sqlite(profile.appending(path: "cookies.sqlite"), ["CREATE TABLE moz_cookies(x)"])
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.tor))
        let found = try #require(source.profiles.first)
        #expect(found.directoryName == "profile.default")
        #expect(found.importableKinds == [.bookmarks])
        #expect(found.availability(of: .cookies) == .unsupported(.refusedForPrivacy))
        #expect(found.availability(of: .history) == .unsupported(.refusedForPrivacy))
    }

    @Test(arguments: [ImportBrowser.safari, .safariTechnologyPreview])
    func safariFamilyWithCookies(_ browser: ImportBrowser) throws {
        let home = try FixtureHome()
        try home.write("x", to: home.directory(browser).appending(path: "Bookmarks.plist"))
        try home.write("cook", to: home.url.appending(path: try #require(browser.safariCookieFile)))
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(browser))
        #expect(source.profiles[0].importableKinds == [.bookmarks, .cookies])
        #expect(!source.needsFullDiskAccess)
    }

    @Test(arguments: [ImportBrowser.orion, .duckDuckGo])
    func webkitBrowsersAreListedButNotImportable(_ browser: ImportBrowser) throws {
        let home = try FixtureHome()
        try FileManager.default.createDirectory(at: home.directory(browser), withIntermediateDirectories: true)
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(browser))
        #expect(source.profiles.count == 1)
        #expect(source.profiles[0].importableKinds.isEmpty)
        #expect(source.profiles[0].availability(of: .passwords) == .unsupported(.exportFromSource))
    }

    @Test func appIsFoundByAnyBundleID() throws {
        let home = try FixtureHome()
        let root = home.directory(.firefox)
        try home.write("[Profile0]\nName=dev\nIsRelative=1\nPath=p\n", to: root.appending(path: "profiles.ini"))
        try FileManager.default.createDirectory(at: root.appending(path: "p"), withIntermediateDirectories: true)
        let environment = ImportEnvironment(homeDirectory: home.url) { id in
            id == "org.mozilla.firefoxdeveloperedition" ? URL(fileURLWithPath: "/Applications/Firefox Developer Edition.app") : nil
        }
        let source = try #require(BrowserSourceDetector(environment: environment).detect(.firefox))
        #expect(source.appURL?.lastPathComponent == "Firefox Developer Edition.app")
    }
}
