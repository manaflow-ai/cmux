import AppKit
import CmuxNextActions
import CmuxNextCompat
import SwiftUI

/// Hosts the Cloud section: follows the machine registry and opens a
/// workspace on a machine through `workspace.newOnMachine`.
final class MachineSectionHostView: NSView, RightSidebarRefreshing {
    let model = MachineSectionModel()
    private unowned let services: AppServices
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        let registry = services.registry
        let hosting = NSHostingView(rootView: MachineSectionListView(model: model, newWorkspace: { id in
            registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string(id)]))
        }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
        let machines = services.machines
        observation = Task { [weak self] in
            for await rows in ObservationStream({ MachineSectionModel.rows(machines) }) {
                self?.model.update(rows)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    func refresh() {
        model.update(MachineSectionModel.rows(services.machines))
    }
}
