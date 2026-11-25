public import CmuxNextActions
import AppKit
import CmuxNextCompat

/// Open in Editor, Open In ▸, Copy Path, Reveal in Finder and Open Terminal Here on a chat's or a workspace's folder
/// (Leo: "what do we think ab this thread?"). The editors are ``EditorCatalog``'s; the App supplies the folder
/// lookups, which refuse with why (a remote or Cloud chat or workspace with `.remote`). A row that cannot run is
/// disabled from the lookup its run uses.
public struct EditorActions {
    public init() {}
    /// The App's side: a chat's folder (`local`: on this Mac only), a workspace's folder on this Mac, the clipboard,
    /// and a terminal tab in a workspace's folder; each lookup returns nil after refusing with why.
    @MainActor public struct Host {
        public var chatFolder: @MainActor (ActionID, ActionInvocation, _ local: Bool) -> String?
        public var workspaceFolder: @MainActor (ActionID, ActionInvocation) -> String?
        public var copy: @MainActor (String) -> Void
        public var openTerminal: @MainActor (String, ActionInvocation) -> ActionEffect

        public init(chatFolder: @escaping @MainActor (ActionID, ActionInvocation, Bool) -> String?, workspaceFolder: @escaping @MainActor (ActionID, ActionInvocation) -> String?,
                    copy: @escaping @MainActor (String) -> Void, openTerminal: @escaping @MainActor (String, ActionInvocation) -> ActionEffect) {
            self.chatFolder = chatFolder
            self.workspaceFolder = workspaceFolder
            self.copy = copy
            self.openTerminal = openTerminal
        }
    }

    @MainActor public static func bind(into registry: ActionRegistry, catalog: EditorCatalog, host: Host) {
        let chat: @MainActor (ActionID, ActionInvocation) -> String? = { host.chatFolder($0, $1, true) }
        let rows: [(ActionID, @MainActor (ActionID, ActionInvocation) -> String?, Bool)] = [
            ("agentPane.openCwdInEditor", chat, false), ("agentPane.openCwdInApp", chat, true),
            ("workspace.openInEditor", host.workspaceFolder, false), ("workspace.openInApp", host.workspaceFolder, true),
        ]
        for (id, folder, needsApp) in rows {
            registry.bindEffect(id, effect: { invocation in
                guard let folder = folder(id, invocation) else { return .done }
                let app = invocation["app"]?.stringValue
                if needsApp, app?.isEmpty != false { return .refused(registry.reason(.needsValue, for: id), quiet: true) }
                return catalog.open([URL(fileURLWithPath: folder, isDirectory: true)], in: app).map { ActionEffect.refused($0) } ?? .done
            })
            registry.gate(id) { invocation in
                if folder(id, invocation) != nil, case .failure(let refusal) = catalog.editor(invocation["app"]?.stringValue) { registry.refuse(refusal.reason, quiet: true) }
            }
        }
        bind("agentPane.copyCwdPath", in: registry, folder: { host.chatFolder($0, $1, false) }) { folder, _ in host.copy(folder); return .done }
        bind("revealWorkspaceInFinder", in: registry, folder: host.workspaceFolder) { folder, _ in
            NSWorkspace.shared.revealInBackground([URL(fileURLWithPath: folder, isDirectory: true)])
            return .done
        }
        bind("workspace.openTerminalHere", in: registry, folder: host.workspaceFolder, run: host.openTerminal)
        catalog.supplyChoices(to: registry, checkedOn: ["agentPane.openCwdInApp", "workspace.openInApp"])
    }

    /// `id` runs `run` on the folder `folder` finds, and is disabled where it finds none.
    @MainActor private static func bind(_ id: ActionID, in registry: ActionRegistry, folder: @escaping @MainActor (ActionID, ActionInvocation) -> String?,
                                        run: @escaping @MainActor (String, ActionInvocation) -> ActionEffect) {
        registry.bindEffect(id, effect: { invocation in folder(id, invocation).map { run($0, invocation) } ?? .done })
        registry.gate(id) { _ = folder(id, $0) }
    }
}
