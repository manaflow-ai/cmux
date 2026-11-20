import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar

/// Edit Group Config… (`workspaceGroup.editConfig`): opens cmux.json in cmux's editor at the
/// group's `workspaceGroups.byCwd` entry, found by the group's anchor folder
/// (``WorkspaceGroupConfigLook``). A group with no entry gets an empty one under its folder
/// (`~/...`), so the editor opens where its settings go.
@MainActor
struct WorkspaceGroupConfigEditor {
    let context: AppActionContext

    /// The group's entry path in the file: its matching key, else a new key for `anchor`.
    static func entryPath(anchor: String, config: WorkspaceGroupConfig, home: String = NSHomeDirectory()) -> (path: [String], exists: Bool) {
        if let key = config.entry(for: anchor, home: home)?.key { return (WorkspaceGroupConfig.byCwdPath + [key], true) }
        return (WorkspaceGroupConfig.byCwdPath + [WorkspaceGroupConfig.key(for: anchor, home: home)], false)
    }

    /// Opens the targeted group's entry, creating it first when missing. Throws the reason it
    /// cannot: no settings yet, or a group whose workspaces have no folder.
    func open(_ invocation: ActionInvocation) throws {
        let group = try context.group(invocation)
        guard let settings = context.services.settings else { throw ActionFailure(message: RefusalStrings.settingsNotLoaded) }
        guard let anchor = anchorDirectory(of: group.id) else { throw ActionFailure(message: RefusalStrings.groupHasNoFolder) }
        let (path, exists) = Self.entryPath(anchor: anchor, config: settings.snapshot.workspaceGroups)
        let file = settings.file, services = context.services
        context.report {
            do {
                if !exists { try await file.set(.object([:]), at: path) }
                let source = try await file.source()
                let place = JSONC.position(of: path, in: source).map { FileLineLocation(line: $0.line, column: $0.column) }
                if !services.linkOpener.openFile(file.url, from: services.windows.active?.focusedPane, line: place) {
                    NSWorkspace.shared.openInBackground(file.url)
                }
                return nil
            } catch {
                return ActionWorkFailure("edit group config", error)
            }
        }
    }

    /// The anchor folder of personal group `id`: its first workspace with a folder, in the order
    /// the active window's sidebar lists the group, else the store's.
    func anchorDirectory(of id: WorkspaceGroupID) -> String? {
        let machines = context.services.machines
        if let model = try? context.sidebar().model, let shown = model.group(model.groupID(personal: id.rawValue)) {
            let listed = shown.workspaces.compactMap { machines.workspace(id: $0.id.rawValue)?.0 }
            if let folder = WorkspaceGroupConfigLook.anchorDirectory(of: listed) { return folder }
        }
        return WorkspaceGroupConfigLook.anchorDirectory(of: context.workspaces(inPersonalGroup: id))
    }
}
