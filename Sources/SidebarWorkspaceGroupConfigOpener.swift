import AppKit
import CmuxWorkspaces
import Foundation

/// Opens workspace-group configuration and documentation surfaces.
enum SidebarWorkspaceGroupConfigOpener {
    /// Opens the cmux config file (`~/.config/cmux/cmux.json`) in the user's
    /// configured editor, materializing an empty config first if none exists.
    @MainActor
    static func openCmuxConfigInEditor() {
        let opener = PreferredEditorService(defaults: .standard)
        openCmuxConfigInEditor(
            home: FileManager.default.homeDirectoryForCurrentUser,
            open: { opener.open($0) }
        )
    }

    /// Testable seam: resolves the cmux config path under `home`, materializes
    /// an empty config if absent, then hands the file to `open`.
    ///
    /// The public ``openCmuxConfigInEditor()`` entry point passes
    /// `PreferredEditorService.open` so the config file honors
    /// `preferredEditorCommand` (with an OS-default fallback). Tests inject a
    /// capturing closure to assert the config file is routed through `open`.
    static func openCmuxConfigInEditor(home: URL, open: (URL) -> Void) {
        open(materializedCmuxConfigURL(home: home))
    }

    /// Resolves `~/.config/cmux/cmux.json` under `home`, materializing an empty
    /// config first if none exists. Shared by the external-editor path above and
    /// in-app openers (e.g. the plus-button menu's "Customize Workspace Layouts…").
    static func materializedCmuxConfigURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let configURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? Data("{}\n".utf8).write(to: configURL, options: .atomic)
            // The config later holds saved actions (commands, URLs, env
            // values); keep it owner-only from the start.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
        }
        return configURL
    }

    static func openWorkspaceGroupsDocs() {
        guard let url = URL(
            string: "https://github.com/manaflow-ai/cmux/blob/main/docs/workspace-groups.md"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
