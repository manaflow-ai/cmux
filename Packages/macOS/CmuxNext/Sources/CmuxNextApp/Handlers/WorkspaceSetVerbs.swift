import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
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
        // A pure lookup (no refusal): the pane a pane or tab target names, if it shows an agent chat or sits on a canvas.
        registry.targetContext = { invocation in
            guard let target = invocation.target else { return [] }
            let services = context.services
            let pane: PaneController? = switch target.kind {
            case .pane: services.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == target.id } }.first
            case .tab: services.locateTab(target.id).flatMap { services.paneController(for: $0.1) }
            default: nil
            }
            var facts: ActionContext = []
            // A pane on a canvas screen brings the canvas actions (CanvasHandlers).
            if let pane, pane.workspace?.layoutModel.canvasScreenID(containing: pane.layoutPaneID) != nil { facts.insert(.canvasLayout) }
            // A pane target brings the chat it shows; a tab target only its own chat, shown in its
            // pane or not (`agent set-model --target tab:…`), never another tab's its pane shows.
            // Either needs a pane a window shows, as the handlers' `ActionScope.pane` does: a parked
            // workspace's cached chat is not one.
            let chatKey = pane == nil ? nil : target.kind == .tab ? target.id : pane?.currentTabKey
            if let chatKey, services.agentTabs.existingView(chatKey) != nil { facts.insert(.agentPaneFocused) }
            return facts
        }
    }

    /// A duplicate of each member (layout, directories, pages), then one new
    /// group of the copies with the group's name (a new group's color, no icon).
    private static func duplicateGroup(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let group = try context.group(invocation)
        let members = try WorkspaceGroupHandlers.members(invocation, context)
        guard !members.isEmpty else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        let bridge = try WorkspaceVerbHandlers.sidebar(showing: members[0], context), name = group.name
        let copies = Copies(expected: members.count)
        let finish: @MainActor @Sendable (String?) -> Void = { id in
            guard let ids = copies.add(id), !ids.isEmpty else { return }
            bridge.groupFlow.newGroup(of: ids.map { SidebarWorkspaceID($0) }, name: name, byUser: false)
        }
        for workspace in members {
            do { try WorkspaceStructureHandlers.duplicate(context, workspace, browsers: true, done: finish) } catch { finish(nil) }
        }
    }

    /// A new workspace listed in the target section: added as its item (Pinned
    /// too), or at the bottom of the window's list for the workspaces section.
    private static func newWorkspace(inSection invocation: ActionInvocation, _ context: AppActionContext) throws {
        let layout = context.services.sidebarLayout
        if let reason = SidebarDocWiring.layoutUnavailableReason(layout) { throw ActionFailure(message: reason) }
        let section = try SidebarSectionResolve.section(invocation.target, in: layout.document)
        switch section.content {
        case .workspaces:
            try WorkspaceVerbHandlers.create(context, invocation, anchorFree: .bottom(anchor: nil))
        case .items:
            let origin = invocation.origin, sectionID = section.id, services = context.services, end = section.items.count
            try WorkspaceVerbHandlers.create(context, invocation, anchorFree: .bottom(anchor: nil)) { id, _ in
                do {
                    try PinCommands(context: AppActionContext(services: services)).dropWorkspaces([id], on: sectionID, at: end, origin: origin)
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
