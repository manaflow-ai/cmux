import Foundation
import Testing
@testable import CmuxNextBrowserImport

@Suite struct DetectionTests {
    @Test func findsChromiumProfilesByLocalStateInOrder() throws {
        let home = try FixtureHome()
        let root = try home.chromium(.chrome, profiles: [("Profile 10", "Side"), ("Default", "Personal"), ("Profile 2", "Work")])
        try home.write("{}", to: root.appending(path: "Default/Bookmarks"))
        try FixtureHome.sqlite(root.appending(path: "Default/History"), ["CREATE TABLE urls(id INTEGER)"])
        try home.write("x", to: root.appending(path: "Default/Login Data"))

        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.chrome))
        #expect(source.profiles.map(\.displayName) == ["Personal", "Work", "Side"])
        let personal = source.profiles[0]
        #expect(personal.id == "chrome/Default")
        #expect(personal.availability(of: .bookmarks) == .available)
        #expect(personal.availability(of: .history) == .available)
        #expect(personal.availability(of: .openTabs) == .absent)
        #expect(personal.availability(of: .passwords) == .available, "read only after the consent step")
        #expect(personal.importableKinds == [.bookmarks, .history, .passwords])
    }

    @Test func readsTheProfilePictureLocalStateNames() throws {
        let home = try FixtureHome()
        let root = home.directory(.edge)
        try home.write(#"{"profile": {"info_cache": {"Default": {"name": "Work", "gaia_picture_file_name": "Edge Profile Picture.png"}, "Profile 1": {"name": "Home", "gaia_picture_file_name": "../escape.png"}, "Profile 2": {"name": "Side", "gaia_picture_file_name": "Missing.png"}}}}"#,
                       to: root.appending(path: "Local State"))
        for dir in ["Default", "Profile 1", "Profile 2"] {
            try home.write("{}", to: root.appending(path: "\(dir)/Preferences"))
            try home.write("{}", to: root.appending(path: "\(dir)/Bookmarks"))
        }
        try home.write("png", to: root.appending(path: "Default/Edge Profile Picture.png"))
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.edge))
        #expect(source.profiles.map(\.avatar?.lastPathComponent) == ["Edge Profile Picture.png", nil, nil],
                "a picture outside the profile folder or one that is gone is not used")
    }

    @Test func findsProfilesWithoutLocalState() throws {
        let home = try FixtureHome()
        let root = home.directory(.brave)
        try home.write("{}", to: root.appending(path: "Default/Preferences"))
        try home.write("{}", to: root.appending(path: "Profile 3/Preferences"))
        try home.write("{}", to: root.appending(path: "System Profile/Preferences"))
        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.brave))
        #expect(source.profiles.map(\.directoryName) == ["Default", "Profile 3"])
    }

    @Test func eachChromiumBrowserUsesItsOwnFolder() throws {
        let home = try FixtureHome()
        for browser in [ImportBrowser.arc, .dia, .helium, .vivaldi, .edge] {
            _ = try home.chromium(browser, profiles: [("Default", browser.displayName)])
        }
        let found = BrowserSourceDetector(environment: home.environment).detect().map(\.browser)
        #expect(found == [.arc, .dia, .edge, .vivaldi, .helium])
    }

    @Test func missingBrowsersAreNotListed() throws {
        let home = try FixtureHome()
        #expect(BrowserSourceDetector(environment: home.environment).detect().isEmpty)
    }

    @Test func firefoxProfilesFromIniDefaultFirst() throws {
        let home = try FixtureHome()
        let root = home.directory(.firefox)
        try home.write("""
            [General]
            StartWithLastProfile=1

            [Profile1]
            Name=work
            IsRelative=1
            Path=Profiles/w.work

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/d.default-release
            Default=1

            [Install4F96D1932A9F858E]
            Default=Profiles/d.default-release
            """, to: root.appending(path: "profiles.ini"))
        try FixtureHome.sqlite(root.appending(path: "Profiles/d.default-release/places.sqlite"), ["CREATE TABLE t(x)"])
        try home.write("{}", to: root.appending(path: "Profiles/d.default-release/extensions.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "Profiles/w.work"), withIntermediateDirectories: true)

        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.firefox))
        #expect(source.profiles.map(\.displayName) == ["default-release", "work"])
        #expect(source.profiles[0].importableKinds == [.bookmarks, .history])
        #expect(source.profiles[0].availability(of: .extensions) == .unsupported(.notChromeExtensions))
        #expect(source.profiles[1].importableKinds.isEmpty)
    }

    @Test func safariBlockedByPrivacyNeedsFullDiskAccess() throws {
        let home = try FixtureHome()
        let root = home.directory(.safari)
        let bookmarks = try home.write("x", to: root.appending(path: "Bookmarks.plist"))
        // An unreadable file stands in for a TCC-protected one (both fail open with EACCES/EPERM).
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bookmarks.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bookmarks.path) }

        let source = try #require(BrowserSourceDetector(environment: home.environment).detect(.safari))
        #expect(source.needsFullDiskAccess)
        #expect(source.profiles[0].availability(of: .bookmarks) == .needsFullDiskAccess)
        #expect(source.profiles[0].availability(of: .history) == .absent)
    }

    @Test func fixtureHomeFromEnvironment() {
        let environment = ImportEnvironment.live(environment: [ImportEnvironment.fixtureHomeKey: "/tmp/fixture-home"]) { _ in
            URL(fileURLWithPath: "/Applications/Real.app")
        }
        #expect(environment.homeDirectory.path == "/tmp/fixture-home")
        #expect(environment.locateApp("com.google.Chrome") == nil)
    }
}
