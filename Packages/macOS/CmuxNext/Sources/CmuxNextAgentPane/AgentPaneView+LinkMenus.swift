public import AppKit
import CmuxNextPages

extension AgentPaneView {
    /// A path part's rows after the pane's own Open (a cmux file page, with its checks): Open in
    /// Text Editor, Open With ▸, Reveal in Finder and Copy Path (``LinkMenu``), for a path inside
    /// the chat's folders, or outside them when `agentPane.links.outsideRoots` is Open. Reply text
    /// names the path, so the default-app Open (which may run it) is left out, and a denied,
    /// missing or confirm-first path, or any path of a chat on another machine, keeps Copy Path
    /// alone (nil).
    func pathMenuItems(_ text: String) -> [NSMenuItem]? {
        // A chat on another machine never offers this Mac's file of the same spelling (cx-k21v).
        guard !model.chatIsElsewhere else { return nil }
        guard let resolved = model.replyPaths().resolve(text) else { return nil }
        switch resolved.place {
        case .root: break
        case .outside where model.replyLinks.settings().outsideRoots == .open: break
        default: return nil
        }
        let file = URL(fileURLWithPath: resolved.path, isDirectory: resolved.isFolder)
        // Each row holds this Mac's file; the chat may turn remote before one is picked, or while
        // its read or panel is still out, so each checks again then (cx-k21v).
        let model = model
        let allowed: @MainActor () -> Bool = { [weak model] in model.map { !$0.chatIsElsewhere } ?? false }
        var menu = LinkMenu()
        menu.allowed = allowed
        // An SVG leaves the pane only as its rebuilt copy (``AgentPaneImageCopies/handedOut(_:in:)``),
        // made when a row is chosen; Open in Text Editor and Copy Path keep the file itself.
        let out = AgentPaneImageCopies.handedOut(file, in: model.replyLinks.imageFolder)
        let handOut: ([NSMenuItem]) -> [NSMenuItem] = { out == file ? $0 : AgentPaneImageCopies.rebuildingFirst($0, file, to: out) }
        let rows = menu.pathRows(for: file, isDirectory: resolved.isFolder).filter { $0.kind != .open }.flatMap { row in
            [.openInTextEditor, .copyPath].contains(row.kind) ? menu.items([row], file: file) : handOut(menu.items([row], file: out))
        }
        // A file (a chip, a video, an audio clip) leads with Copy and Save As…; a folder has neither.
        let fileRows = AgentPaneFileRows(copyItem: { [weak model] in model?.replyLinks.copyItem($0) ?? false },
                                         save: { [weak model] in model?.replyLinks.savePathFile($0, $1, allowed) },
                                         allowed: allowed)
        let items = resolved.isFolder ? rows : handOut(fileRows.items(for: out)) + [.separator()] + rows
        // The gate wraps the SVG rebuild, so a row checks before the rebuild and again when it acts.
        Self.gate(items, allowed: allowed)
        return items
    }

    /// Makes every row of `items` (and of their submenus) run only while `allowed()` holds.
    static func gate(_ items: [NSMenuItem], allowed: @escaping @MainActor () -> Bool) {
        for item in items {
            if let submenu = item.submenu { gate(submenu.items, allowed: allowed) }
            guard let action = item.action, let target = item.representedObject as? NSObject ?? item.target as? NSObject else { continue }
            let gated = AgentPaneMenuAction { [weak item] in
                guard allowed() else { return }
                _ = target.perform(action, with: item)
            }
            item.target = gated
            item.action = #selector(AgentPaneMenuAction.run)
            item.representedObject = gated
        }
    }
}

#if DEBUG
extension AgentPaneView {
    /// `debug.terminal.links agentLink` (DEBUG): opens `url` as a click on a link in an agent
    /// chat does: the gesture rule (one recorded click), then the pane's own opener (the shared
    /// link rule). True when it opened.
    public static func debugOpenClickedLink(_ url: URL) -> Bool {
        let gestures = AgentPaneUserGestures()
        gestures.record(click: true)
        return AgentPaneNavigation.openOutside(url, gestures: gestures) { routedOpenURL($0, []) }
    }
}
#endif
