import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextDiff
import Foundation
import Testing

/// `<config dir>/diff/theme.css` (customization.md D55, rule 4): every diff tab gets the user's
/// stylesheet from `cmux.diff.theme` and each later save from the stream of the same name, "" once
/// the file is gone, the way the agent pane and the file pages load theirs. `cmux customize`
/// accepted the file before any page read it.
@MainActor
@Suite(.serialized)
struct DiffUserThemeTests {
    private struct Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "cnc-diff-theme-\(UUID().uuidString)")
        var configFile: URL { root.appending(path: "cmux-next.json") }
        var css: URL { DiffThemeFeed.stylesheet(configFile: configFile) }

        func write(_ text: String) throws {
            try FileManager.default.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: css, options: .atomic)
        }
    }

    /// Waits until `ready` holds, at most 5 s: a watcher event takes as long as the machine needs.
    private static func waitUntil(_ ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    @Test func theStylesheetSitsInTheDiffFolderNextToTheSettingsFile() {
        let file = DiffThemeFeed.stylesheet(configFile: URL(fileURLWithPath: "/Users/me/.config/cmux/cmux-next.json"))
        #expect(file.path == "/Users/me/.config/cmux/diff/theme.css")
        let runtime = DiffPageRuntime(sidecar: .some(nil), configFile: URL(fileURLWithPath: "/tmp/x/cmux-next.json"))
        #expect(runtime.theme.file.path == "/tmp/x/diff/theme.css")
    }

    @Test func aTabGetsTheFileThenEverySaveThenEmptyAfterDelete() async throws {
        let home = Home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try home.write(":root { --cmux-diff-gap: 2px }\n")
        let provider = DiffPageProvider(ready: nil, sidecar: nil, languages: nil, theme: DiffThemeFeed(file: home.css))
        let context = PageCallContext(page: "cmux.diff")

        let first = try await provider.call("cmux.diff.theme", params: [:], context: context)
        #expect(first == ["themeCSS": ":root { --cmux-diff-gap: 2px }\n"])

        var pushed: [String] = []
        let subscription = try await provider.subscribe("cmux.diff.theme", filter: .null, context: context) { value in
            pushed.append(value["themeCSS"]?.stringValue ?? "<missing>")
        }
        defer { subscription.cancel() }

        // An editor's atomic save (rename over the file) reaches the open tab.
        try home.write(":root { --cmux-diff-gap: 9px }\n")
        #expect(await Self.waitUntil { pushed.last == ":root { --cmux-diff-gap: 9px }\n" }, "pushed: \(pushed)")

        // Deleting it clears the tab's stylesheet.
        try FileManager.default.removeItem(at: home.css)
        #expect(await Self.waitUntil { pushed.last == "" }, "pushed: \(pushed)")
        #expect(!pushed.contains("<missing>"))
    }

    @Test func aFolderMadeLaterIsSeenAndTheWatchStopsWithTheLastTab() async throws {
        let home = Home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        let feed = DiffThemeFeed(file: home.css)
        #expect(await feed.css() == "")

        var pushed: [String] = []
        let stop = feed.listen { pushed.append($0) }
        #expect(feed.isWatching)
        try home.write("body { color: red }")
        #expect(await Self.waitUntil { pushed.last == "body { color: red }" }, "pushed: \(pushed)")

        stop()
        #expect(feed.listenerCount == 0)
        #expect(!feed.isWatching)
    }

    @Test func aTabWithoutTheFeedAnswersUnknownOp() async throws {
        let provider = DiffPageProvider(ready: nil, sidecar: nil, languages: nil)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.theme", params: [:], context: PageCallContext(page: "cmux.diff"))
        }
    }
}
