import AppKit
import CmuxNextCompat
package import CmuxNextActions

/// Thread title and local editor actions shared by the chat header.
@MainActor
package struct AgentChatThreadActions {
    package init() {}

    /// Connects the header's thread actions to the app's current tab and folder wiring.
    package func wire(_ header: inout AgentPaneHeaderHooks?, tab: @escaping @MainActor () -> String,
                      registry: @escaping @MainActor () -> ActionRegistry?, cwd: @escaping @MainActor (String) -> String?,
                      local: @escaping @MainActor (String) -> Bool,
                      files: @escaping @MainActor (String, String) -> Void,
                      changes: @escaping @MainActor (String, String) -> Void) {
        header?.openHere = { action, folder in
            let current = tab()
            return openHere(action, cwd: folder, fallback: { cwd(current) }, local: { local(current) },
                            files: { files($0, current) }, changes: { changes($0, current) })
        }
        header?.rename = { rename($0, tab: tab(), registry: registry()) }
        header?.openIn = { openIn(cwd(tab()), app: $0) }
    }

    /// Opens the Files or Changes tile in the page's own pane.
    private func openHere(_ action: String, cwd: String?, fallback: () -> String?, local: () -> Bool,
                          files: (String) -> Void, changes: (String) -> Void) -> Bool {
        guard let folder = cwd ?? fallback(), !folder.isEmpty else { return false }
        switch action {
        case "files":
            // Files reads this Mac's folders only.
            guard local() else { return false }
            files(folder)
        case "openDiffViewer": changes(folder)
        default: return false
        }
        return true
    }

    /// The header's thread title: the chat's tab takes `name`, as Rename Tab with a name does;
    /// whether the action ran.
    private func rename(_ name: String, tab: String, registry: ActionRegistry?) -> Bool {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), arguments: ["name": .string(name)], origin: .user)
        return registry?.perform("renameTab", invocation: invocation) ?? false
    }

    /// Thread details' Open in: the apps this Mac has that open a folder (Finder always), by id and
    /// name; with `app`, `folder` opens there first. Editors are matched by bundle id, never a path.
    private func openIn(_ folder: String?, app: String?) -> [[String: String]] {
        let editors: [(id: String, name: String, bundle: String?)] = [
            ("finder", "Finder", nil), ("vscode", "VS Code", "com.microsoft.VSCode"),
            ("cursor", "Cursor", "com.todesktop.230313mzl4w4u92"), ("zed", "Zed", "dev.zed.Zed"),
            ("xcode", "Xcode", "com.apple.dt.Xcode"),
        ]
        let workspace = NSWorkspace.shared
        let appURL = { (bundle: String?) -> URL? in
            bundle.map { workspace.urlForApplication(withBundleIdentifier: $0) } ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        }
        let installed = editors.filter { appURL($0.bundle) != nil }
        if let app, let folder, folder.hasPrefix("/"), let pick = installed.first(where: { $0.id == app }) {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            if pick.bundle != nil, let at = appURL(pick.bundle) {
                workspace.open([url], withApplicationAt: at, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.openInBackground(url)
            }
        }
        return installed.map { editor in
            var row = ["id": editor.id, "name": editor.name]
            if let at = appURL(editor.bundle), let icon = Self.icon(at) { row["icon"] = icon }
            return row
        }
    }

    /// An app's icon as a 64px PNG data URL (16pt at 2x and 3x) for the page's Open in rows, kept
    /// per app. Taken from the icon's own best image: drawn into a small bitmap it came out blurred
    /// on a grey tile.
    private static var icons: [URL: String] = [:]
    private static func icon(_ app: URL) -> String? {
        if let cached = icons[app] { return cached }
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let image = NSWorkspace.shared.icon(forFile: app.path)
            .cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high.rawValue]),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        icons[app] = url
        return url
    }
}
