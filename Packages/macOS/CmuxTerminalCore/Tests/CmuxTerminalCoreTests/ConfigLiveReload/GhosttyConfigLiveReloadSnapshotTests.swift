import CoreText
import Foundation
import Testing
@testable import CmuxTerminalCore

/// In-memory config files keyed by absolute path.
private struct InMemoryConfigFiles: GhosttyConfigFileReading {
    var contentsByPath: [String: String]

    func fileSize(atPath path: String) -> Int? {
        contentsByPath[path].map { $0.lengthOfBytes(using: .utf8) }
    }

    func contents(atPath path: String) -> String? {
        contentsByPath[path]
    }
}

private struct NoFonts: GhosttyFontProbing {
    func discoveredFont(named _: String, size _: CGFloat, weightTrait _: CGFloat?) -> CTFont? { nil }
    func configuredFont(named _: String, size _: CGFloat) -> CTFont? { nil }
}

@Suite struct GhosttyConfigLiveReloadSnapshotTests {
    private func snapshot(
        _ files: [String: String],
        topLevelPaths: [String] = ["/home/.config/ghostty/config", "/home/.config/ghostty/config.ghostty"]
    ) -> GhosttyConfigLiveReloadSnapshot {
        GhosttyConfigDiscovery(
            fileReader: InMemoryConfigFiles(contentsByPath: files),
            fontProbe: NoFonts()
        ).liveReloadSnapshot(
            topLevelPaths: topLevelPaths,
            configHomeDirectory: "/home/.config",
            resolvesSymlinks: false
        )
    }

    @Test func watchesMissingTopLevelCandidatesSoCreatingOneIsNoticed() {
        let result = snapshot(["/home/.config/ghostty/config": "font-size = 13\n"])

        #expect(result.watchedPaths == [
            "/home/.config/ghostty/config",
            "/home/.config/ghostty/config.ghostty",
        ])
        #expect(result.contentsByPath == ["/home/.config/ghostty/config": "font-size = 13\n"])
    }

    @Test func followsRelativeOptionalAndNestedConfigFileIncludes() {
        let result = snapshot([
            "/home/.config/ghostty/config": """
            config-file = colors.conf
            config-file = ?"/opt/shared/optional.conf"
            """,
            "/home/.config/ghostty/colors.conf": "config-file = nested/keys.conf\n",
            "/home/.config/ghostty/nested/keys.conf": "keybind = cmd+k=clear_screen\n",
        ])

        #expect(result.watchedPaths.contains("/home/.config/ghostty/colors.conf"))
        #expect(result.watchedPaths.contains("/opt/shared/optional.conf"))
        #expect(result.watchedPaths.contains("/home/.config/ghostty/nested/keys.conf"))
        #expect(result.contentsByPath["/home/.config/ghostty/nested/keys.conf"] == "keybind = cmd+k=clear_screen\n")
        #expect(result.contentsByPath["/opt/shared/optional.conf"] == nil)
    }

    @Test func includeCycleTerminates() {
        let result = snapshot([
            "/home/.config/ghostty/config": "config-file = a.conf\n",
            "/home/.config/ghostty/a.conf": "config-file = config\n",
        ])

        #expect(result.watchedPaths.filter { $0 == "/home/.config/ghostty/config" }.count == 1)
        #expect(result.watchedPaths.contains("/home/.config/ghostty/a.conf"))
    }

    @Test func watchesUserThemeFilesForBothSidesOfAConditionalTheme() {
        let result = snapshot([
            "/home/.config/ghostty/config": "theme = light:Paper,dark:Night Owl\n",
            "/home/.config/ghostty/themes/Night Owl": "background = #011627\n",
        ])

        #expect(result.watchedPaths.contains("/home/.config/ghostty/themes/Paper"))
        #expect(result.watchedPaths.contains("/home/.config/ghostty/themes/Night Owl"))
        #expect(result.contentsByPath["/home/.config/ghostty/themes/Night Owl"] == "background = #011627\n")
    }

    @Test func watchesAbsoluteThemePathAsWritten() {
        let result = snapshot([
            "/home/.config/ghostty/config": "theme = /Users/me/themes/custom\n",
        ])

        #expect(result.watchedPaths.contains("/Users/me/themes/custom"))
        #expect(!result.watchedPaths.contains { $0.hasSuffix("ghostty/themes//Users/me/themes/custom") })
    }

    @Test func themeEditChangesContentsButNotWatchedPaths() {
        let before = snapshot([
            "/home/.config/ghostty/config": "theme = Mine\n",
            "/home/.config/ghostty/themes/Mine": "background = #000000\n",
        ])
        let after = snapshot([
            "/home/.config/ghostty/config": "theme = Mine\n",
            "/home/.config/ghostty/themes/Mine": "background = #111111\n",
        ])

        #expect(before.watchedPaths == after.watchedPaths)
        #expect(!before.hasSameContents(as: after))
    }

    @Test func liveReloadTopLevelPathsIncludeLegacyAndCmuxCandidatesThatDoNotExist() {
        let discovery = GhosttyConfigDiscovery(
            fileReader: InMemoryConfigFiles(contentsByPath: [:]),
            fontProbe: NoFonts()
        )
        let appSupport = URL(fileURLWithPath: "/nonexistent-cmux-live-reload-test/Application Support")

        let paths = discovery.liveReloadTopLevelPaths(
            currentBundleIdentifier: "com.cmuxterm.app.debug.tag",
            appSupportDirectory: appSupport
        )

        let base = appSupport.path
        #expect(paths.contains("\(base)/com.mitchellh.ghostty/config.ghostty"))
        #expect(paths.contains("\(base)/com.mitchellh.ghostty/config"))
        #expect(paths.contains("\(base)/com.cmuxterm.app/config.ghostty"))
        #expect(paths.contains("\(base)/com.cmuxterm.app.debug.tag/config.ghostty"))
        #expect(Set(paths).count == paths.count)
    }
}
