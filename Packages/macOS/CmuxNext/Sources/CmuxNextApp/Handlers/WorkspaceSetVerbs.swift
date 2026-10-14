import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSidebar

/// Verbs on sets of workspaces and windows from the action audit (cx-5qewo,
/// Lawrence 2026-10-14): Close Other Windows, Duplicate Workspace Group, New
/// Workspace in Section; and the facts an explicit target brings to a run, so
/// a script can archive the agent chat of a pane it names.
enum WorkspaceSetVerbs {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("window.closeOthers", run: { invocation in
            let keep = try context.window(invocation)
            // Each window's own close check (an incognito window asks); terminals keep running.
            for controller in context.services.windows.controllers where controller !== keep {
                if let window = controller.window { WindowTargeting.close(window) }
            }
        })
        registry.bind("workspaceGroup.duplicate", run: { try duplicateGroup($0, context) })
        registry.bind("sidebar.section.newWorkspace", run: { try newWorkspace(inSection: $0, context) })
        registry.targetContext = { invocation in
            guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                  context.services.agentTabs.existingView(key) != nil else { return [] }
            return .agentPaneFocused
        }
    }

    /// A duplicate of each member (layout, directories, pages), then one new
    /// group of the copies with the group's name.
    private static func duplicateGroup(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let group = try context.group(invocation)
        let members = try WorkspaceGroupHandlers.members(invocation, context)
        guard !members.isEmpty else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        let bridge = try context.sidebar(), name = group.name
        let copies = Copies(expected: members.count)
        for workspace in members {
            try WorkspaceStructureHandlers.duplicate(context, workspace, browsers: true) { id in
                guard let ids = copies.add(id), !ids.isEmpty else { return }
                bridge.groupFlow.newGroup(of: ids.map(SidebarWorkspaceID.init), name: name, byUser: false)
            }
        }
    }

    /// A new workspace listed in the target section: added as its item (Pinned
    /// too), or at the bottom of the window's list for the workspaces section.
    private static func newWorkspace(inSection invocation: ActionInvocation, _ context: AppActionContext) throws {
        let layout = context.services.sidebarLayout
        if let reason = layout.unavailableReason { throw ActionFailure(message: reason) }
        let section = try SidebarSectionResolve.section(invocation.target, in: layout.document)
        switch section.content {
        case .workspaces:
            try WorkspaceVerbHandlers.create(context, invocation, anchorFree: .bottom(anchor: nil))
        case .items:
            let origin = invocation.origin, sectionID = section.id, services = context.services
            try WorkspaceVerbHandlers.create(context, invocation, anchorFree: .bottom(anchor: nil)) { id, _ in
                do {
                    try PinCommands(context: AppActionContext(services: services)).dropWorkspaces([id], on: sectionID, at: Int.max, origin: origin)
                } catch {
                    services.registry.refuse(RefusalStrings.describe(error))
                }
            }
        case .app:
            throw ActionFailure(message: RefusalStrings.sectionTakesNoWorkspaces)
        }
    }
}

/// The copies of a group duplicate as they finish; `add` returns every new id
/// once the last one reports.
@MainActor
private final class Copies {
    private let expected: Int
    private var made: [String?] = []

    init(expected: Int) { self.expected = expected }

    func add(_ id: String?) -> [String]? {
        made.append(id)
        return made.count == expected ? made.compactMap { $0 } : nil
    }
}
