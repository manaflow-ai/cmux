import Foundation
import Testing
@testable import CmuxSettings

@Suite("Video background config editor", .serialized)
struct VideoBackgroundConfigEditorTests {
    @Test
    func updatesQueueQualityVolumeAndPreservesOtherConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-video-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cmux.json")
        try """
        {
          // Keep this unrelated setting.
          "app": { "appearance": "dark" },
          "terminal": { "videoBackground": { "enabled": false } }
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        let editor = VideoBackgroundConfigEditor(fileURL: url)
        let result = try editor.update(.init(
            enabled: true,
            source: " https://youtu.be/dQw4w9WgXcQ ",
            queue: [" first ", "", "second"],
            muted: false,
            quality: "4k",
            volume: 0.35,
            dimOpacity: 0.8
        ))

        #expect(result.enabled == true)
        #expect(result.source == "https://youtu.be/dQw4w9WgXcQ")
        #expect(result.queue == ["first", "second"])
        #expect(result.quality == "2160p")
        #expect(result.volume == 0.35)
        #expect(result.dimOpacity == 0.8)

        let raw = try String(contentsOf: url, encoding: .utf8)
        let root = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect((root["app"] as? [String: Any])?["appearance"] as? String == "dark")
    }

    @Test
    func acceptsJSONCAndFollowsAConfigSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-video-editor-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("cmux.json")
        try "{ \"terminal\": { } }".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let editor = VideoBackgroundConfigEditor(fileURL: link)
        _ = try editor.update(.init(source: "dQw4w9WgXcQ", queue: ["dQw4w9WgXcQ"]))
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(!destination.isEmpty)
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
        let targetRoot = try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: target)) as? [String: Any])
        let video = ((targetRoot["terminal"] as? [String: Any])?["videoBackground"] as? [String: Any])
        #expect((video?["queue"] as? [String]) == ["dQw4w9WgXcQ"])
    }
}
