import AppKit
import CmuxNextActions
import CmuxNextDaemon
import UniformTypeIdentifiers

/// The workspace checklist actions (`workspace-checklist-v1`): add, toggle, complete, mark in
/// progress, edit, remove and attach images edit the daemon's checklist through one path
/// (``WorkspaceChecklistEdit``); Open Todo Pane and Open Checklist as Pane show the Todo page.
/// The palette, the workspace menu, Cmd-Return, the Todo page and the CLI (`cmux action run`,
/// MCP) all run these handlers.
enum WorkspaceChecklistHandlers {
    static let editIDs: [ActionID] = [
        "palette.addWorkspaceChecklistItem", "toggleChecklistItemComplete", "checklistCompleteItem",
        "checklistMarkInProgress", "checklistEditItem", "checklistRemoveItem", "checklistAttachImages",
    ]
    static let pageIDs: [ActionID] = ["palette.openWorkspaceTodoPane", "checklistOpenAsPane"]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let capability = DaemonCapability.workspaceChecklist.rawValue
        let services = context.services
        services.pages.register(services.workspaceTodo) // at launch, so a restored tab finds it
        for id in editIDs {
            registry.bind(id, requires: capability, daemon: services.activeDaemon, run: { invocation in
                let target = try Target(invocation, context: context, capability: capability)
                if id == "checklistAttachImages", invocation["path"] == nil {
                    let item = try WorkspaceChecklistEdit.target(invocation, items: target.workspace.checklist)
                    return pickImages(for: item.id, target: target, registry: registry, services: services)
                }
                apply(try WorkspaceChecklistEdit.make(for: id, invocation: invocation, items: target.workspace.checklist), to: target)
            })
        }
        for id in pageIDs {
            registry.bind(id, requires: capability, daemon: services.activeDaemon, run: { invocation in
                let workspace = try context.workspace(invocation).model
                try services.workspaceTodo.show(workspaceID: workspace.id, focus: invocation.allowsViewChange)
            })
        }
    }

    /// The workspace a checklist action edits and the daemon that keeps its checklist.
    struct Target {
        let workspace: WorkspaceModel
        let daemon: DaemonService
        let resource: ResourceID

        init(_ invocation: ActionInvocation, context: AppActionContext, capability: String) throws {
            let workspace = try context.workspace(invocation).model
            let daemon = context.services.machines.daemon(forWorkspace: workspace.id) ?? context.services.activeDaemon
            guard daemon.supports(capability) else { throw ActionFailure(message: daemon.missingCapabilityMessage(capability)) }
            guard let key = workspace.key, let resource = daemon.store.stateResourceID(workspace: key) else {
                throw ActionFailure.needsDaemonCapability(DaemonCapability.stateResources.rawValue)
            }
            self.workspace = workspace
            self.daemon = daemon
            self.resource = resource
        }
    }

    /// Sends `edit` to the daemon; the `session.events` upsert then updates every surface.
    static func apply(_ edit: WorkspaceChecklistEdit, to target: Target) {
        let resource = target.resource
        switch (edit.operation, edit.item) {
        case (.add, _):
            let text = edit.text ?? ""
            target.daemon.send("workspace-checklist-add") { try await $0.state.addChecklistItem(resource, text: text) }
        case (.update, let item?):
            let (text, state, attachments) = (edit.text, edit.state, edit.attachments)
            target.daemon.send("workspace-checklist-update") {
                try await $0.state.updateChecklistItem(resource, item: item, text: text, state: state, attachments: attachments)
            }
        case (.remove, let item?):
            target.daemon.send("workspace-checklist-remove") { try await $0.state.removeChecklistItem(resource, item: item) }
        case (.update, nil), (.remove, nil):
            break
        }
    }

    /// Attach Images without a `path`: the cmux picker (R96, no NSOpenPanel) chooses the images,
    /// then they join the item's current attachments.
    private static func pickImages(for item: String, target: Target, registry: ActionRegistry, services: AppServices) {
        registry.track(Task { @MainActor in
            let options = CmuxPicker.OpenOptions(choose: .files, allowsMultiple: true, types: [.image])
            guard let urls = await services.viewers.picker.open(options), !urls.isEmpty,
                  let current = target.workspace.checklist.first(where: { $0.id == item }) else { return nil }
            apply(WorkspaceChecklistEdit.attaching(urls.map(\.path), to: current), to: target)
            return nil
        })
    }
}
