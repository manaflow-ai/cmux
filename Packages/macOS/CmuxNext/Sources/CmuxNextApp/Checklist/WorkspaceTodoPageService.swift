import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextPages
import SwiftUI
import CmuxNextTasks

extension InternalPageID {
    static let workspaceTodo = InternalPageID(rawValue: "workspace-todo")
}

/// Owns the Todo page (`palette.openWorkspaceTodoPane`, `checklistOpenAsPane`): an internal page
/// tab, one per window, that shows one workspace's checklist (`workspace-checklist-v1`) and edits
/// it through the checklist actions. The tab's route is the workspace id, so a reopened tab shows
/// the same checklist.
@MainActor
final class WorkspaceTodoPageService: InternalPageProvider {
    private weak var services: AppServices?
    /// Each tab's model, by key: kept from its first view until the tab closes, so a view made again
    /// after a discard shows the same workspace and the unsent draft.
    private(set) var models: [String: WorkspaceTodoPageModel] = [:]
    /// The workspace a restored tab shows, by tab key.
    private var pending: [String: String] = [:]
    /// The workspace each show asked for, for the tab it opened or selected.
    private let opens = PageOpenRequests<String>()

    init(services: AppServices) {
        self.services = services
    }

    /// Shows the Todo tab of the active window, else opens one, listing `workspaceID`'s checklist.
    func show(workspaceID: String, focus: Bool) throws {
        guard let services, let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        guard let view = opens.open(workspaceID, { services.pages.show(.workspaceTodo, in: window, focus: focus) }) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        // A tab with no view yet lists it at its first show.
        models[view.key]?.workspaceID = workspaceID
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .workspaceTodo }
    var title: String { WorkspaceChecklistStrings.pageTitle }
    var symbol: String { "checklist" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let requested = opens.take(for: key)
        let restored = pending.removeValue(forKey: key)
        if let model = models[key] {
            if let requested { model.workspaceID = requested }
            return VisibilityGatedHostingView(owner: "WorkspaceTodoPage") { WorkspaceTodoPageView(model: model) }
        }
        let id = requested ?? restored ?? opens.running ?? window?.state.workspaceID ?? ""
        let model = WorkspaceTodoPageModel(
            workspaceID: id,
            workspace: { [weak self] in self?.services?.workspace(id: $0) },
            perform: { [weak self] id, invocation in _ = self?.services?.registry.perform(id, invocation: invocation) })
        models[key] = model
        return VisibilityGatedHostingView(owner: "WorkspaceTodoPage") { WorkspaceTodoPageView(model: model) }
    }

    func tabClosed(_ key: String) {
        models.removeValue(forKey: key)
        pending.removeValue(forKey: key)
        opens.forget(key)
    }

    func route(for key: String) -> String? { models[key]?.workspaceID ?? opens.kept(for: key) ?? pending[key] }

    func restore(_ route: String, for key: String) { pending[key] = route }

    // MARK: Discard

    /// Ten minutes hidden (Chrome's proactive_discarding_policy.cc). The model stays with the tab,
    /// so the rebuilt view shows the same checklist and draft.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// An item whose text is being edited keeps the view: the edited text lives in its row.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        models[key]?.editing == nil ? [] : [.unsavedEdits]
    }
}
