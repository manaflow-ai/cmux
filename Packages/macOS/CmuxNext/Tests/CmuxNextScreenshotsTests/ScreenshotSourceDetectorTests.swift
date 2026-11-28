@testable import CmuxNextScreenshots
import Foundation
import Testing

/// A fake Mac: preferences and files in memory, folders on disk under a temporary home.
nonisolated struct FixtureEnvironment: ScreenshotEnvironment {
    var homeDirectory: URL
    var temporaryDirectory: URL
    var preferences: [String: [String: String]] = [:]
    var files: [String: String] = [:]

    func preference(_ key: String, domain: String) -> String? { preferences[domain]?[key] }
    func stringPreferences(domain: String) -> [String: String] { preferences[domain] ?? [:] }
    func text(at url: URL) -> String? { files[url.path] }
    func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

@Suite struct ScreenshotSourceDetectorTests {
    let home: TemporaryFolder
    let temp: TemporaryFolder

    init() throws {
        home = try TemporaryFolder()
        temp = try TemporaryFolder()
        try home.folder("Desktop")
        try temp.folder("TemporaryItems")
    }

    func environment(_ preferences: [String: [String: String]] = [:], files: [String: String] = [:]) -> FixtureEnvironment {
        FixtureEnvironment(homeDirectory: home.url, temporaryDirectory: temp.url, preferences: preferences, files: files)
    }

    @Test func withNothingSetItListsTheDesktopAndThePreviewFolder() {
        let sources = ScreenshotSourceDetector(environment: environment()).detect(findTools: true, extraFolders: [])
        #expect(sources.map(\.id) == ["system", "system.preview"])
        #expect(sources[0].folder.path == home.url.appendingPathComponent("Desktop").path)
        #expect(sources[1].folder.path == temp.url.appendingPathComponent("TemporaryItems").path)
        #expect(sources[1].rule.folderPrefix == "NSIRD_screencaptureui_")
        #expect(sources[1].rule.depth == 1)
        #expect(sources[0].acceptsDrops)
        #expect(!sources[1].acceptsDrops)
    }

    @Test func readsTheScreencaptureLocationWithATilde() throws {
        try home.folder("screenshots")
        let env = environment(["com.apple.screencapture": ["location": "~/screenshots"]])
        let sources = ScreenshotSourceDetector(environment: env).detect(findTools: false, extraFolders: [])
        #expect(sources.first?.folder.path == home.url.appendingPathComponent("screenshots").path)
    }

    @Test func aMissingLocationFallsBackToTheDesktop() {
        let env = environment(["com.apple.screencapture": ["location": "/nowhere/\(UUID().uuidString)"]])
        #expect(ScreenshotSourceDetector(environment: env).systemFolder().lastPathComponent == "Desktop")
    }

    /// This Mac's setup: CleanShot X exports into the macOS folder (shown once) and keeps a history.
    @Test func cleanShotIntoTheMacOSFolderShowsOnceAndItsHistoryShowsToo() throws {
        let shots = try home.folder("screenshots")
        try home.folder("Library/Application Support/CleanShot/media")
        let env = environment([
            "com.apple.screencapture": ["location": "~/screenshots"],
            "pl.maketheweb.cleanshotx": ["exportPath": shots.path],
        ])
        let sources = ScreenshotSourceDetector(environment: env).detect(findTools: true, extraFolders: [])
        #expect(sources.map(\.id) == ["system", "system.preview", "tool.cleanShotX.history"])
        let history = try #require(sources.last)
        #expect(history.label.contains("CleanShot X"))
        #expect(history.rule.folderPrefix == "media_")
        #expect(history.origin == .toolHistory(.cleanShotX))
        #expect(!history.acceptsDrops)
    }

    @Test func readsKapAndFlameshotSettingsFiles() throws {
        let kap = try home.folder("Kaps")
        let flame = try home.folder("Flames")
        let env = environment(files: [
            home.url.appendingPathComponent("Library/Application Support/Kap/config.json").path: #"{"kapturesDir": "\#(kap.path)"}"#,
            home.url.appendingPathComponent(".config/flameshot/flameshot.ini").path: "[General]\nsavePath=~/Flames\n",
        ])
        let sources = ScreenshotSourceDetector(environment: env).detect(findTools: true, extraFolders: [])
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        #expect(byID["tool.kap"]?.folder.path == kap.path)
        #expect(byID["tool.kap"]?.rule.kinds == [.image, .video])
        #expect(byID["tool.flameshot"]?.folder.path == flame.path)
    }

    /// A tool whose key the detector does not know: any string preference naming an existing folder.
    @Test func findsAnUnknownKeyThatNamesAFolder() throws {
        let saves = try home.folder("ShottrSaves")
        let env = environment(["cc.ffitch.shottr": ["NSWindowFrame": "1 2 3 4", "theme": "dark", "defaultSaveFolder": saves.path]])
        let sources = ScreenshotSourceDetector(environment: env).detect(findTools: true, extraFolders: [])
        #expect(sources.first { $0.id == "tool.shottr" }?.folder.path == saves.path)
        #expect(ScreenshotSourceDetector.looksLikeFolderKey("exportPath"))
        #expect(ScreenshotSourceDetector.looksLikeFolderKey("SaveLocation"))
        #expect(!ScreenshotSourceDetector.looksLikeFolderKey("NSOSPLastRootDirectory"))
        #expect(!ScreenshotSourceDetector.looksLikeFolderKey("recentFolders"))
        #expect(!ScreenshotSourceDetector.looksLikeFolderKey("theme"))
    }

    @Test func toolsOffListsOnlyMacOSAndThePersonsFolders() throws {
        try home.folder("Library/Application Support/CleanShot/media")
        try home.folder("Pictures/Mine")
        let sources = ScreenshotSourceDetector(environment: environment()).detect(findTools: false, extraFolders: ["~/Pictures/Mine", "relative/ignored"])
        #expect(sources.map(\.origin) == [.system, .systemPreview, .custom])
        #expect(sources.last?.label == "Mine")
        #expect(sources.last?.acceptsDrops == true)
    }

    @Test func aFolderThatDoesNotExistIsNotListed() {
        let sources = ScreenshotSourceDetector(environment: environment()).detect(findTools: true, extraFolders: ["/nowhere/\(UUID().uuidString)"])
        #expect(sources.map(\.id) == ["system", "system.preview"])
    }

    @Test func settingsFileFormats() {
        #expect(ScreenshotSettingsFileFormat.ini.value(of: "savePath", in: "[General]\n savePath = /a/b \nother=1") == "/a/b")
        #expect(ScreenshotSettingsFileFormat.ini.value(of: "savePath", in: "savePath=") == nil)
        #expect(ScreenshotSettingsFileFormat.json.value(of: "kapturesDir", in: #"{"kapturesDir":"/k"}"#) == "/k")
        #expect(ScreenshotSettingsFileFormat.json.value(of: "kapturesDir", in: "not json") == nil)
    }
}
