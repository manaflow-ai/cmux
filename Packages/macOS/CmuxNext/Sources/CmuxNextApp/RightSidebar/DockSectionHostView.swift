import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextWakeups
import SwiftUI

/// Hosts the Dock section for one window: follows the shown workspace's
/// layout (its `LayoutModel` is observable) and runs the column actions
/// through the registry.
final class DockSectionHostView: NSView, RightSidebarRefreshing {
    let model = DockSectionModel()
    private weak var controller: WindowController?
    /// This view in the visibility tree: the columns render only while it is on screen, and once on show.
    let visibility = ViewVisibility("dock-section")
    var visibilityNode: VisibilityNode { visibility.node }
    private let mainWork: MainWorkScheduler
    private var observation: VisibleObservation<[DockColumn]>?

    init(controller: WindowController) {
        self.controller = controller
        mainWork = controller.services.mainWork
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        let registry = controller.services.registry
        let actions = DockSectionActions(
            focus: { [weak controller] pane in controller?.focus.send(.focusPane(pane, source: .intent)) },
            undock: { id in registry.perform("column.undock", invocation: ActionInvocation(target: ActionTargetRef(kind: .column, id: id))) },
            dockFocused: { registry.perform("column.dock", invocation: ActionInvocation()) })
        // hosting-gate: opt-out a right sidebar section, not tab content: it shows while the sidebar does.
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
    }

    override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    /// Reads the shown workspace now and follows its layout until the next refresh: a view observation on
    /// this view's node, so a hidden section renders nothing and renders once on show.
    func refresh() {
        observation?.cancel()
        observation = nil
        guard let content = controller?.content else { return model.update(columns: [], title: { _ in nil }) }
        let layout = content.layoutModel
        observation = VisibleObservation(visibility.node, owner: "DockSection.columns", on: mainWork) {
            layout.activeScreen?.layout.columns.compactMap(\.dock) ?? []
        } apply: { [weak self, weak content] _ in
            guard let self, let content else { return }
            update(from: content)
        }
    }

    private func update(from content: WorkspaceContentController) {
        model.update(columns: content.layoutModel.activeScreen?.layout.columns ?? []) {
            content.paneController(key: $0.rawValue)?.selectedTab?.title
        }
    }
}
