import CmuxNextActions
import CmuxNextCloud
import Foundation
import Testing

/// plans/cmux-next/links.json states cmux-next's links for clients that make
/// the same links (GPUI's Copy Link): each build's scheme from
/// `CloudConfiguration` (what the app registers), the shape and the id rules
/// from `DeepLink`. Stale file: `CMUX_UPDATE_ACTION_SURFACES=1 swift test
/// --filter LinkExportTests` (scripts/measure/export-action-surfaces.sh).
struct LinkExportTests {
    static func scheme(_ bundleID: String, debug: Bool, tag: String? = nil) -> String {
        CloudConfiguration.resolve(bundleID: bundleID, bundled: tag.map { ["CMUX_TAG": $0] } ?? [:], process: [:],
                                   isDebugBuild: debug).callbackScheme
    }

    static var export: DeepLinkExport {
        DeepLinkExport(schemes: [
            .init(build: "release", bundleID: "com.cmuxterm.app", scheme: scheme("com.cmuxterm.app", debug: false)),
            .init(build: "nightly", bundleID: "com.cmuxterm.app.nightly", scheme: scheme("com.cmuxterm.app.nightly", debug: false)),
            .init(build: "rc", bundleID: "com.cmuxterm.app.rc", scheme: scheme("com.cmuxterm.app.rc", debug: false)),
            .init(build: "debug", bundleID: "com.cmuxterm.app.debug", scheme: scheme("com.cmuxterm.app.debug", debug: true)),
            .init(build: "tagged", bundleID: nil, scheme: scheme("com.cmuxterm.app.debug.my-tag", debug: true, tag: "My Tag_1"),
                  exampleTag: "My Tag_1"),
        ])
    }

    static func planURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("plans/cmux-next/\(name)")
    }

    @Test func linksJSONIsFresh() throws {
        let url = Self.planURL("links.json")
        let current = Self.export.json()
        #expect(!current.isEmpty)
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_ACTION_SURFACES"] == "1" {
            try current.write(to: url, atomically: true, encoding: .utf8)
        }
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored == current, "links.json is stale; rerun with CMUX_UPDATE_ACTION_SURFACES=1")
    }

    /// The file's facts are the code's: the schemes, the release target, and
    /// every example parses back with `DeepLink.parse` to its kind.
    @Test func theExportStatesWhatTheCodeDoes() throws {
        #expect(Self.export.targetScheme == "cmux")
        #expect(Self.export.schemes.map(\.scheme) == ["cmux", "cmux-nightly", "cmux-rc", "cmux-dev", "cmux-dev-my-tag-1"])
        let data = try Data(contentsOf: Self.planURL("links.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["target_scheme"] as? String == "cmux")
        let kinds = try #require(root["kinds"] as? [[String: Any]])
        #expect(kinds.compactMap { $0["kind"] as? String } == ["workspace", "pane", "tab", "session"])
        for kind in kinds {
            let text = try #require(kind["example"] as? String)
            let url = try #require(URL(string: text))
            let link = try #require(DeepLink.parse(url, scheme: "cmux"), "\(text) parses")
            switch (kind["kind"] as? String, link.target) {
            case ("workspace", .workspace), ("pane", .pane), ("tab", .tab), ("session", .session(_, turn: nil)): break
            default: Issue.record("\(text) is not a \(kind["kind"] ?? "?") link")
            }
        }
        let turn = try #require(kinds.last?["example_with_turn"] as? String)
        #expect(DeepLink.parse(try #require(URL(string: turn)), scheme: "cmux") == DeepLink(.session("ses-01.example_a", turn: "turn_7")))
        // The id rules the file states hold in the code: 32 lowercase hex digits only.
        #expect(DeepLink(.tab("tab_" + String(repeating: "a", count: 31))).url(scheme: "cmux") == nil)
        #expect(DeepLink(.tab("tab_" + String(repeating: "A", count: 32))).url(scheme: "cmux") == nil)
        #expect(DeepLink(.tab("tab_" + String(repeating: "a", count: 32))).url(scheme: "cmux") != nil)
    }
}
