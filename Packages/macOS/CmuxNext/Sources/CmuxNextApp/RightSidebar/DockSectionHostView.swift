import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextLayout
import SwiftUI

/// Hosts the Dock section for one window: follows the shown workspace's
/// layout (its `LayoutModel` is observable) and runs the column actions
/// through the registry.
final class DockSectionHostView: NSView, RightSidebarRefreshing {
    let model = DockSectionModel()
    private weak var controller: WindowController?
    private var observation: Task<Void, Never>?

    init(controller: WindowController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        let registry = controller.services.registry
        let actions = DockSectionActions(
            focus: { [weak controller] pane in controller?.focus.send(.focusPane(pane, source: .intent)) },
            undock: { id in registry.perform("column.undock", invocation: ActionInvocation(target: ActionTargetRef(kind: .column, id: id))) },
            dockFocused: { registry.perform("column.dock", invocation: ActionInvocation()) })
        let hosting = NSHostingView(rootView: DockSectionListView(model: model, actions: actions))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
    }

    /// Reads the shown workspace now and follows its layout until the next refresh.
    func refresh() {
        observation?.cancel()
        guard let content = controller?.content else { return model.update(columns: [], title: { _ in nil }) }
        update(from: content)
        let layout = content.layoutModel
        observation = Task { [weak self, weak content] in
            for await _ in ObservationStream({ layout.activeScreen?.layout.columns.compactMap(\.dock) ?? [] }) {
                guard let self, let content else { return }
                update(from: content)
            }
        }
    }

    private func update(from content: WorkspaceContentController) {
        model.update(columns: content.layoutModel.activeScreen?.layout.columns ?? []) {
            content.paneController(key: $0.rawValue)?.selectedTab?.title
        }
    }
}
