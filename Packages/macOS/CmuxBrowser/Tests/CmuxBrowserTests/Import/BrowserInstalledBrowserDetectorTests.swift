import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserInstalledBrowserDetector")
struct BrowserInstalledBrowserDetectorTests {
    /// Builds a temporary fake home directory and returns its URL plus a
    /// teardown closure.
    private func makeTempHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-import-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("detects a Chromium browser from its on-disk Default profile")
    func detectsChromiumFromData() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Lay down ~/Library/Application Support/Google/Chrome/Default/History.
        let chromeRoot = home
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let defaultProfile = chromeRoot.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultProfile, withIntermediateDirectories: true)
        try Data().write(to: defaultProfile.appendingPathComponent("History"))

        let detector = BrowserInstalledBrowserDetector(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: [],
            fileManager: .default
        )

        let candidates = detector.detectInstalledBrowsers()
        let chrome = try #require(candidates.first { $0.id == "google-chrome" })
        #expect(chrome.family == .chromium)
        #expect(chrome.appURL == nil)
        #expect(chrome.profiles.contains { $0.isDefault })
        #expect(chrome.detectionScore > 0)
    }

    @Test("detects Dia Chromium profiles under User Data")
    func detectsDiaProfilesUnderUserData() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let diaUserDataRoot = home
            .appendingPathComponent("Library/Application Support/Dia/User Data", isDirectory: true)
        let defaultProfile = diaUserDataRoot.appendingPathComponent("Default", isDirectory: true)
        let workProfile = diaUserDataRoot.appendingPathComponent("Profile 1", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultProfile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workProfile, withIntermediateDirectories: true)
        try Data().write(to: defaultProfile.appendingPathComponent("Cookies"))
        try Data().write(to: workProfile.appendingPathComponent("Cookies"))
        try Data(
            """
            {
              "profile": {
                "info_cache": {
                  "Default": {
                    "name": "Personal"
                  },
                  "Profile 1": {
                    "name": "Work"
                  }
                }
              }
            }
            """.utf8
        ).write(to: diaUserDataRoot.appendingPathComponent("Local State"))

        let detector = BrowserInstalledBrowserDetector(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: [],
            fileManager: .default
        )

        let dia = try #require(detector.detectInstalledBrowsers().first { $0.id == "dia" })
        #expect(dia.family == .chromium)
        #expect(dia.dataRootURL == diaUserDataRoot)
        #expect(dia.profiles.map(\.displayName) == ["Personal", "Work"])
        #expect(dia.profiles.map(\.rootURL.lastPathComponent) == ["Default", "Profile 1"])
    }

    @Test("detects a Firefox browser and reads its profiles.ini name")
    func detectsFirefoxFromINI() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let firefoxRoot = home
            .appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
        let profileDir = firefoxRoot.appendingPathComponent("abc.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try Data().write(to: profileDir.appendingPathComponent("places.sqlite"))
        let ini = """
        [Profile0]
        Name=My Work Profile
        IsRelative=1
        Path=abc.default-release
        Default=1
        """
        try ini.write(to: firefoxRoot.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)

        let detector = BrowserInstalledBrowserDetector(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: [],
            fileManager: .default
        )

        let firefox = try #require(detector.detectInstalledBrowsers().first { $0.id == "firefox" })
        #expect(firefox.family == .firefox)
        #expect(firefox.profiles.contains { $0.displayName == "My Work Profile" && $0.isDefault })
    }

    @Test("an app-only hit still produces a candidate via bundle lookup")
    func detectsAppOnlyFromBundleLookup() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fakeApp = home.appendingPathComponent("Arc.app", isDirectory: true)
        let detector = BrowserInstalledBrowserDetector(
            homeDirectoryURL: home,
            bundleLookup: { bundleID in bundleID == "company.thebrowser.Browser" ? fakeApp : nil },
            applicationSearchDirectories: [],
            fileManager: .default
        )

        let arc = try #require(detector.detectInstalledBrowsers().first { $0.id == "arc" })
        #expect(arc.appURL == fakeApp)
        #expect(arc.detectionScore >= 80)
    }

    @Test("nothing installed yields no candidates")
    func detectsNothing() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let detector = BrowserInstalledBrowserDetector(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: [],
            fileManager: .default
        )
        #expect(detector.detectInstalledBrowsers().isEmpty)
    }

    @Test("summaryText lists names and summarizes overflow")
    func summaryText() {
        let detector = BrowserInstalledBrowserDetector()
        #expect(detector.summaryText(for: []).contains("No supported"))

        let candidates = (0..<6).map { index in
            InstalledBrowserCandidate(
                descriptor: BrowserImportBrowserDescriptor.allBrowserDescriptors[index],
                resolvedFamily: .chromium,
                homeDirectoryURL: URL(fileURLWithPath: "/"),
                appURL: nil,
                dataRootURL: nil,
                profiles: [],
                detectionSignals: [],
                detectionScore: 1
            )
        }
        let summary = detector.summaryText(for: candidates, limit: 4)
        #expect(summary.contains("more"))
    }
}
