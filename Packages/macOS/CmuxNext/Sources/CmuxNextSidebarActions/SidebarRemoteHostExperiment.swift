public import AppKit
import CmuxNextDesign
public import CmuxNextActions
public import CmuxNextSettings
public import CmuxNextSidebar

/// The opt-in host menu and its address field belong to the sidebar window that was clicked.
@MainActor
public final class SidebarRemoteHostExperiment {
    private let addressField = PopupTextEntry()
    public init() {}

    public func menu(_ menu: NSMenu?, for target: SidebarContextTarget, anchoredIn sidebar: NSView,
                     settings: CmuxConfigSnapshot?, registry: ActionRegistry,
                     startSession: @escaping @MainActor (MachineID) async -> ActionWorkFailure?) -> NSMenu? {
        guard let menu, settings?.root.value(at: ["labs", "sidebarRemoteHosts"])?.boolValue == true else { return menu }
        switch target {
        case .section(.machine(let machine)) where machine != .local:
            menu.insertItem(RemoteHostMenuAction.item(Self.newSession) {
                // task-owner: one workspace creation for this menu selection.
                registry.trackOrRefuse(Task { await startSession(machine) })
            }, at: 0)
            return menu
        case .background: break
        default: return menu
        }
        if let start = registry.makeMenuItem(for: "palette.newAgentChat") {
            start.title = Self.newSession
            menu.insertItem(start, at: 0)
        }
        let index = min(1, menu.items.count)
        // Save the anchor now. Menu tracking moves the pointer away from the original click.
        let point = sidebar.convert(sidebar.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        menu.insertItem(RemoteHostMenuAction.item(Self.addHost) { [weak self, weak sidebar] in
            guard let self, let sidebar else { return }
            let hint = String(localized: "remoteHost.address", defaultValue: "Type a tailnet name or SSH URL", bundle: .module)
            addressField.show(in: sidebar, at: point, placeholder: hint) { address in
                Self.run("remote.newGroup", ["destination": .string(address)], registry)
            }
        }, at: index)
        if let customize = registry.makeMenuItem(for: "sidebar.customize") {
            customize.title = String(localized: "remoteHost.customize", defaultValue: "Customize View…", bundle: .module)
            menu.insertItem(customize, at: index + 1)
        }
        return menu
    }

    private static var newSession: String { String(localized: "remoteHost.newSession", defaultValue: "New Session", bundle: .module) }
    private static var addHost: String { String(localized: "remoteHost.add", defaultValue: "Add Remote Host…", bundle: .module) }
    private static func run(_ id: ActionID, _ args: [String: ActionValue], _ registry: ActionRegistry) {
        var invocation = ActionInvocation(arguments: args, focusRequested: true)
        invocation.menuPick = true
        _ = registry.perform(id, invocation: invocation)
    }
}

@MainActor
private final class RemoteHostMenuAction: NSObject {
    let work: @MainActor () -> Void
    init(_ work: @escaping @MainActor () -> Void) { self.work = work }
    @objc private func perform(_ sender: NSMenuItem) { work() }
    static func item(_ title: String, _ work: @escaping @MainActor () -> Void) -> NSMenuItem {
        let owner = RemoteHostMenuAction(work)
        let item = NSMenuItem(title: title, action: #selector(perform(_:)), keyEquivalent: "")
        item.target = owner
        item.representedObject = owner
        return item
    }
}
