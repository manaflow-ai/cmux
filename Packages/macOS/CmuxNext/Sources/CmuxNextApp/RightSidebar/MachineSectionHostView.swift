import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextServer
import CmuxNextWakeups
import SwiftUI

/// Hosts the Machines section: follows the machine registry and each machine's last check, opens a
/// workspace on a machine through `workspace.newOnMachine` and Add Device through `device.add`.
final class MachineSectionHostView: NSView, RightSidebarRefreshing {
    let model = MachineSectionModel()
    private let machines: MachineRegistry
    private let health: MachineHealthStore
    /// This view in the visibility tree: the rows render only while it is on screen, and once on show.
    let visibility = ViewVisibility("machines-section")
    var visibilityNode: VisibilityNode { visibility.node }
    private var observation: VisibleObservation<[MachineSectionRow]>?

    convenience init(services: AppServices) {
        self.init(machines: services.machines, health: services.machineHealth, registry: services.registry,
                  mainWork: services.mainWork)
    }

    /// - Parameters:
    ///   - machines: The machines the rows list.
    ///   - health: Each machine's last check.
    ///   - registry: Runs New Workspace (`workspace.newOnMachine`) and Add Device (`device.add`).
    ///   - mainWork: The app's main-thread scheduler the rows' observation runs on.
    init(machines: MachineRegistry, health: MachineHealthStore, registry: ActionRegistry, mainWork: MainWorkScheduler) {
        self.machines = machines
        self.health = health
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        // hosting-gate: opt-out a right sidebar section, not tab content: it shows while the sidebar does.
        let hosting = NSHostingView(rootView: MachineSectionListView(model: model, newWorkspace: { id in
            registry.perform("workspace.newOnMachine", invocation: ActionInvocation(arguments: ["machine": .string(id)]))
        }, addMachine: { registry.perform("device.add") }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // A view observation on this view's node (its first value applies now): a hidden section renders
        // nothing and renders once on show.
        observation = VisibleObservation(visibility.node, owner: "MachineSection.rows", on: mainWork) {
            MachineSectionModel.rows(machines, health: health)
        } apply: { [weak self] rows in
            self?.model.update(rows)
        }
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

    func refresh() {
        model.update(MachineSectionModel.rows(machines, health: health))
    }
}
