import AppKit
import CmuxNextActions

/// App actions on an agent chat's own tab: the header's tools and "..." menu
/// (acpmux header/ChatHeaderTools.tsx), the empty-space right-click menu (`agentChat`
/// placements) and Search the Web on selected text. Kept off `AgentTabStore`, whose wiring is
/// at its type budget.
@MainActor
struct AgentChatTabActions {
    /// The chat's tab now (a provisional id becomes the store's).
    let tab: @MainActor () -> String
    let registry: @MainActor () -> ActionRegistry?
    /// Opens the Files tree of a folder beside the chat (AgentTabStore.openFiles), on tab `target` or in a new column.
    var files: @MainActor (_ folder: String, _ target: String?) -> Void = { _, _ in }
    /// The empty-space menu's rows that don't apply to this chat now (Move to Cloud on a chat of another machine).
    var hidden: @MainActor () -> Set<ActionID> = { [] }
    /// Ghostty's `split-inherit-working-directory` (NewTerminalStart, cx-zld.1).
    var splitInherits: @MainActor () -> Bool = { NewTerminalStart.inherits(.split) }
    /// The chat's folder is on this Mac: the inherit keys apply only here (NewTerminalStart).
    var local: @MainActor () -> Bool = { true }

    /// A header action, with the folder it names when it names one, on the chat's tab or on tab
    /// `target` (a header split opening right of the one before it, AgentChatSplitToggles).
    func run(_ id: String, cwd: String?, on target: String? = nil) {
        // The header's Terminal names the chat's folder, the one a split inherits: with Ghostty's
        // `split-inherit-working-directory = false` it names none, and the split starts in the home
        // folder as any split does (PaneHandlers.split, NewTerminalStart). Only for a chat on this Mac:
        // the key is this Mac's, and a chat of another machine keeps its folder.
        let terminal = id == "splitRight" || id == "splitDown"
        let cwd = terminal && local() && !splitInherits() ? nil : cwd
        let arguments: [String: ActionValue] = cwd.map { ["cwd": .string($0)] } ?? [:]
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? tab()), arguments: arguments, origin: .user)
        // The header's Terminal and Split Down open a terminal, not the New Tab page a person's split from a chat opens.
        invocation.opensTerminal = terminal
        _ = registry()?.perform(ActionID(rawValue: id), invocation: invocation)
    }

    /// Runs `id` (Changes' diff viewer, Preview's browser) as an agent's beside_caller run, keeping
    /// focus in the chat: its tab opens selected in tab `target`'s column, or with no target in a new
    /// column right of the chat.
    func runBeside(_ id: String, arguments: [String: ActionValue], on target: String?) {
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: target ?? tab()), arguments: arguments, origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = target == nil
        _ = registry()?.perform(ActionID(rawValue: id), invocation: invocation)
    }

    /// The header's Files (cx-p4rt): the tree of `folder` beside the chat, as ``runBeside(_:arguments:on:)`` places a diff.
    func openFiles(_ folder: String?, on target: String?) {
        if let folder, !folder.isEmpty { files(folder, target) }
    }

    /// The header's thread title: the chat's tab takes `name`, as Rename Tab with a name does;
    /// whether the action ran.
    func rename(_ name: String) -> Bool {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab()), arguments: ["name": .string(name)], origin: .user)
        return registry()?.perform("renameTab", invocation: invocation) ?? false
    }

    /// Thread details' Open in: the apps this Mac has that open a folder (Finder always), by id and
    /// name; with `app`, `folder` opens there first. Editors are matched by bundle id, never a path.
    func openIn(_ folder: String?, app: String?) -> [[String: String]] {
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
                workspace.open(url)
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

    /// Closes tab `id` (a quick action's split, AgentChatSplitToggles) as its own Close Tab does.
    func close(tab id: String) {
        _ = registry()?.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user))
    }

    /// The "..." menu's Move to Floating Chat: once `float` put session `id` in Start Agent's
    /// panel, the chat's tab closes as its own Close Tab does.
    func moveToFloatingChat(_ id: String, via float: (@MainActor (String) -> Bool)?) -> Bool {
        guard float?(id) == true else { return false }
        close(tab: tab())
        return true
    }

    /// Search the Web on selected chat text: a browser tab beside the chat, with the omnibar's
    /// search engine.
    func searchWeb(_ text: String) {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab()), arguments: ["text": .string(text)], origin: .user)
        _ = registry()?.perform("browser.selection.search", invocation: invocation)
    }

    /// The empty-space menu's items, detached for the pane's menu to take.
    func menuItems() -> [NSMenuItem] {
        guard let registry = registry() else { return [] }
        let menu = registry.makeContextMenu(for: .agentChat, target: ActionTargetRef(kind: .tab, id: tab()),
                                            entries: ContextMenuCatalog.shared.entries(for: .agentChat, removing: hidden()))
        let items = menu.items
        menu.removeAllItems()
        return items
    }
}
