import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// A YouTube wallpaper (`youtube:<VIDEO_ID>[?start=S][&end=E][&quality=Q]`) is accepted wherever
/// a video file is: the background, Light and Dark, a schedule, and the picker's rows.
@Suite struct YouTubeBackdropSettingTests {
    static func parse(_ root: JSONValue) -> (BackdropSelection?, [SettingsDiagnostic]) {
        var diagnostics: [SettingsDiagnostic] = []
        let selection = BackdropSelectionSetting().parse(root, diagnostics: &diagnostics)
        return (selection, diagnostics)
    }

    @Test func theBackgroundAndLightAndDarkTakeYouTubeIDs() throws {
        let video = try #require(BackdropYouTube(id: "youtube:dQw4w9WgXcQ?start=30&end=90"))
        let (one, problems) = Self.parse(["appearance": ["background": "youtube:dQw4w9WgXcQ?start=30&end=90"]])
        #expect(one == .youtube(video) && problems.isEmpty)
        let root: JSONValue = ["appearance": ["background": "appearance", "backgroundLight": "youtube:dQw4w9WgXcQ",
                                              "backgroundDark": "youtube:aqz-KE-bpKQ?quality=2160"]]
        let (pair, pairProblems) = Self.parse(root)
        let dark = try #require(BackdropYouTube(videoID: "aqz-KE-bpKQ", quality: 2160))
        #expect(pair == .pair(light: .youtube(try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ"))), dark: .youtube(dark)))
        #expect(pairProblems.isEmpty)
        #expect(pair?.id == "appearance:youtube:dQw4w9WgXcQ|youtube:aqz-KE-bpKQ?quality=2160", "a | crept into an id")
        #expect(pair?.resolved(dark: true) == .youtube(dark) && pair?.youtube != nil)
        // A link is the Rust side's to turn into an id; the setting keeps ids only.
        let (link, linkProblems) = Self.parse(["appearance": ["background": "https://youtu.be/dQw4w9WgXcQ"]])
        #expect(link == BackdropSelectionSetting.defaultSelection && !linkProblems.isEmpty)
    }

    @Test func everyBackgroundKeyAcceptsYouTubeIDs() {
        #expect(BackdropSelectionSetting.accepts("youtube:dQw4w9WgXcQ") && !BackdropSelectionSetting.accepts("youtube:short"))
        #expect(BackdropSelectionSetting.acceptsPicture("youtube:dQw4w9WgXcQ?end=60"))
        #expect(!BackdropSelectionSetting.acceptsPicture("youtube:dQw4w9WgXcQ?quality=1080"), "a default is spelled out")
        #expect(BackdropSelectionSetting.acceptsSchedule(.object(["sunset": "youtube:dQw4w9WgXcQ", "07:00": "desktop"])))
    }

    @Test func thePickerListsUsedVideosAsMovingWallpapers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-youtube-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = BackdropYouTubeLibrary(folder: folder)
        let first = try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ"))
        let second = try #require(BackdropYouTube(videoID: "aqz-KE-bpKQ", start: 5, end: 65))
        try library.add(first, title: "Never Gonna Give You Up")
        try library.add(second)
        #expect(library.list() == [second, first], "newest first")
        let catalog = BackdropCatalog(systemDirectory: folder.appendingPathComponent("none"), fileManager: .default,
                                      userImages: BackdropUserImages(folder: folder), aerials: folder.appendingPathComponent("none"))
        #expect(catalog.choices.contains(.youtube(first)) && catalog.choices.contains(.youtube(second)))
        guard case .array(let rows) = catalog.pageRows else { Issue.record("rows are not an array"); return }
        let row = try #require(rows.first { $0["id"]?.stringValue == first.id })
        #expect(row["title"]?.stringValue == "Never Gonna Give You Up")
        #expect(row["attribution"]?.stringValue == "YouTube · Never Gonna Give You Up")
        #expect(row["collection"]?.stringValue == AppleWallpapers.videoCollection && row["video"] == .bool(true))
        #expect(row["youtube"]?["video"]?.stringValue == "dQw4w9WgXcQ" && row["youtube"]?["end"] == .null)
        let untitled = try #require(rows.first { $0["id"]?.stringValue == second.id })
        #expect(untitled["title"]?.stringValue == "aqz-KE-bpKQ", "an untitled video shows its id")
        #expect(untitled["youtube"]?["start"] == .number(5) && untitled["youtube"]?["end"] == .number(65))
        try library.remove(first)
        #expect(library.list() == [second])
    }
}
