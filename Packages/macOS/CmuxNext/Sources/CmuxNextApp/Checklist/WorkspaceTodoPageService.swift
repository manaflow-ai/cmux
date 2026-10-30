import AppKit
import CmuxNextActions
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
    private var models: [String: WorkspaceTodoPageModel] = [:]
    /// The workspace the next new tab shows (set by a show or a restore).
    private var pending: [String: String] = [:]
    private var next: String?

    init(services: AppServices) {
        self.services = services
    }

    /// Shows the Todo tab of the active window, else opens one, listing `workspaceID`'s checklist.
    func show(workspaceID: String, focus: Bool) throws {
        guard let services, let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        next = workspaceID
        defer { next = nil }
        guard let view = services.pages.show(.workspaceTodo, in: window, focus: focus) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        models[view.key]?.workspaceID = workspaceID
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .workspaceTodo }
    var title: String { WorkspaceChecklistStrings.pageTitle }
    var symbol: String { "checklist" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let id = pending.removeValue(forKey: key) ?? next ?? window?.state.workspaceID ?? ""
        let model = WorkspaceTodoPageModel(
            workspaceID: id,
            workspace: { [weak self] in self?.services?.workspace(id: $0) },
            perform: { [weak self] id, invocation in _ = self?.services?.registry.perform(id, invocation: invocation) })
        models[key] = model
        return NSHostingView(rootView: WorkspaceTodoPageView(model: model))
    }

    func tabClosed(_ key: String) {
        models.removeValue(forKey: key)
        pending.removeValue(forKey: key)
    }

    func route(for key: String) -> String? { models[key]?.workspaceID }

    func restore(_ route: String, for key: String) { pending[key] = route }
}
