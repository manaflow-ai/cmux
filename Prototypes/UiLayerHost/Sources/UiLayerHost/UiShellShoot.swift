import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import UiShellShootKit

// The UI shell's one-shot mode (Leo, ask-8bdd370f5f: "literally the shell, like you literally just ship the shell"):
// `cmux-ui-layer --shoot DIR [--scene a,b] [--themes DIR]` opens the real modules' playground windows, the same ones
// the app's Debug menu opens, and draws each into a PNG (UiShellShootKit). It links only the leaf UI modules
// (CmuxNextUiShellModules), never the app composition root, the daemon, Ghostty or Chromium, so a changed UI file
// costs a leaf rebuild. The heavy modules' scenes live in their own hosts (cmux-ui-home, cmux-ui-app) so that a leaf
// change never waits on them.

@MainActor
enum UiShellShoot {
    nonisolated static var repoThemes: URL { UiShellShooter.repoThemes }

    /// Every theme file's colors in `folder`, by file name.
    static func themeColors(in folder: URL) -> [String: ThemeFileColors] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var colors: [String: ThemeFileColors] = [:]
        for name in names {
            guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8),
                  let file = ThemeFileColors(name: name, themeFile: text) else { continue }
            colors[name] = file
        }
        return colors
    }

    /// The scenes, each holding its playground's owner so its window lives until the shot.
    static func scenes(themes: URL) -> [UiShellScene] {
        let colors = themeColors(in: themes)
        let tabs = TabBarPlaygroundWindow()
        let sidebar = SidebarStatesPlaygroundWindow(design: .shared)
        let allThemes = AllThemesPlaygroundWindow(folders: [themes])
        let keycaps = CmuxKeycapPlaygroundWindow()
        return [
            UiShellScene(name: "tabs", module: "CmuxNextTabs") { tabs.show() },
            UiShellScene(name: "sidebar-states", module: "CmuxNextSidebar") {
                sidebar.show(themes: SidebarStatesPlaygroundThemes(colors: colors))
            },
            UiShellScene(name: "all-themes", module: "CmuxNextDesign") { allThemes.show() },
            UiShellScene(name: "keycaps", module: "CmuxNextDesign") {
                keycaps.show(themes: CmuxToastPlaygroundThemes(colors: colors))
            },
        ]
    }

    /// Shoots `options.scenes` (every scene when empty) into `options.output` and writes receipt.json there.
    static func run(_ options: UiShellShootOptions) throws -> UiShellReceipt {
        try UiShellShooter.run(options, scenes: scenes(themes: options.themes))
    }
}
