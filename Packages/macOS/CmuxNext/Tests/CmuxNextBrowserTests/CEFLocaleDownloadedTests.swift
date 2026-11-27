import Foundation
import Testing

@testable import CmuxNextBrowser

/// The Chromium UI locale when only `en` stays in the framework and the person's language pak
/// arrives on first use into a folder outside it (CMUX-570).
struct CEFLocaleDownloadedTests {
    /// A framework folder with `en.lproj` only and a downloaded folder with these `.lproj` folders
    /// (true: holds a `locale.pak`), removed with the returned scratch root.
    private func layout(downloaded: [String: Bool]) throws -> (root: URL, framework: URL, downloaded: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-locale-\(UUID().uuidString)", directoryHint: .isDirectory)
        let framework = root.appending(path: "framework", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: framework.appending(path: "Resources/en.lproj"), withIntermediateDirectories: true)
        let folder = root.appending(path: "downloaded", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, hasPak) in downloaded {
            let lproj = folder.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            if hasPak { try Data([1]).write(to: lproj.appending(path: "locale.pak")) }
        }
        return (root, framework, folder)
    }

    @Test func englishOnlyFrameworkResolvesEnglish() throws {
        let dirs = try layout(downloaded: [:])
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let locale = CEFLocale.current(frameworkDirectory: dirs.framework, preferredLanguages: ["de-US", "ja"])
        #expect(locale.locale == "en-US")
    }

    @Test func downloadedPakIsUsedForItsLanguage() throws {
        let dirs = try layout(downloaded: ["de.lproj": true])
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let locale = CEFLocale.current(frameworkDirectory: dirs.framework, downloadedDirectory: dirs.downloaded,
                                       preferredLanguages: ["de-US"])
        #expect(locale.locale == "de")
    }

    @Test func aFolderWithoutAPakFallsBackToEnglish() throws {
        let dirs = try layout(downloaded: ["fr.lproj": false])
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let locale = CEFLocale.current(frameworkDirectory: dirs.framework, downloadedDirectory: dirs.downloaded,
                                       preferredLanguages: ["fr-US"])
        #expect(locale.locale == "en-US")
    }
}
