@testable import CmuxNextApp
import CmuxNextTerminal
import Foundation
import Testing

/// The app watches the finalized Ghostty file graph and asks libghostty to
/// reload after an edit. The test injects the graph so it also covers an
/// include that appears after the first reload.
@MainActor
struct GhosttyConfigLiveReloadTests {
    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition was not reached")
    }

    private static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-ghostty-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func anEditReloadsOnceAndAnewIncludeIsWatched() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appending(path: "config")
        let include = root.appending(path: "profile")
        try Data("font-size = 13\n".utf8).write(to: config)

        var watched = [config.path]
        var reloadCount = 0
        let center = NotificationCenter()
        let liveReload = GhosttyConfigLiveReload(
            files: { watched },
            reload: {
                reloadCount += 1
                if reloadCount == 1 {
                    watched.append(include.path)
                    center.post(name: GhosttyRuntime.configDidChange, object: nil)
                }
            },
            notifications: center
        )
        liveReload.start()
        defer { liveReload.stop() }

        try Data("font-size = 14\n".utf8).write(to: config, options: .atomic)
        try await Self.waitUntil { reloadCount == 1 }

        // The config-change notification re-arms the graph after libghostty
        // has resolved the include set.
        try await Task.sleep(for: .milliseconds(100))
        try Data("font-size = 15\n".utf8).write(to: include, options: .atomic)
        try await Self.waitUntil { reloadCount == 2 }
    }

    @Test func candidatePathsIncludeXDGAndApplicationSupport() {
        let home = URL(fileURLWithPath: "/tmp/cmux-home")
        let appSupport = home.appending(path: "Library/Application Support", isDirectory: true)
        let paths = GhosttyRuntime.defaultConfigCandidatePaths(
            homeDirectory: home,
            applicationSupportDirectory: appSupport,
            environment: ["XDG_CONFIG_HOME": "/tmp/cmux-xdg"]
        )
        #expect(paths == [
            "/tmp/cmux-xdg/ghostty/config",
            "/tmp/cmux-xdg/ghostty/config.ghostty",
            "/tmp/cmux-home/Library/Application Support/com.mitchellh.ghostty/config",
            "/tmp/cmux-home/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
    }
}
