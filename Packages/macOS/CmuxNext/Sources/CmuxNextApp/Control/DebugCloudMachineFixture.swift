#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.cloud_machine_fixture {sidebar?, menu?, name?, window?}` (DEBUG builds, captures of a Cloud
/// machine's right-click menu). A capture slot is signed out of cmux Cloud and has no Cloud machine,
/// so a Cloud machine header's menu there hides every row that needs `cloudWorkspace` (its Tools
/// folder's Apply Machine Config and Deliver Secrets among them), and no menu change could show a
/// before and after. A real machine would cost money and show account names.
/// - `sidebar: true`: the window's sidebar shows a fixture This Mac and a Cloud machine named `name`
///   (default `demo-cloud`), a section each, and the action registry holds `cloudWorkspace` as it
///   does while a Cloud machine's workspace is active (``seed(_:)``); `false` brings the live rows
///   and context back. The machine is a sidebar row and nothing else: no session, no sign-in, no
///   network call, no Cloud state.
/// - `menu: true`: a right-click on that header (`debug.mouse`), so its menu opens as the
///   person's does (`SidebarContextMenus.machineMenu`); a `debug.key` sequence opens a folder.
/// Answers the machine id, whether the registry holds `cloudWorkspace`, and the header's frame.
@MainActor
enum DebugCloudMachineFixture {
    /// The fixture machine's id when the call names none.
    static let defaultName = "demo-cloud"

    /// While true, `cloudContextDidChange` keeps `cloudWorkspace` (AppServices+Cloud). Only
    /// ``seed(_:)`` sets it, and this whole type is DEBUG only, so a Release build never holds it.
    private(set) static var holdsCloudWorkspace = false

    /// Holds (or, `false`, drops) `cloudWorkspace` in the registry's context, as a Cloud machine's
    /// active workspace does, without a session or a sign-in.
    static func seed(_ services: AppServices, _ on: Bool = true) {
        holdsCloudWorkspace = on
        services.cloudContextDidChange()
    }

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let name = params["name"]?.stringValue ?? defaultName
        let machine = MachineID(name)
        guard let controller = services.windows.controllers.first(where: { c in params["window"]?.stringValue.map { $0 == c.state.id } ?? true })
                ?? services.windows.active else {
            return .object(["error": .string("no window")])
        }
        let sidebar = controller.sidebar
        if let show = params["sidebar"]?.boolValue {
            // Machine headers are drawn only with a section per computer (`sidebar.groupByComputer`).
            DesignSettings.shared.sidebarSections.groupsByComputer = show
                || (services.settings?.snapshot.sidebarSections ?? .defaults).groupsByComputer
            sidebar.rows.fixture = show ? fixture(machine: machine, name: name) : nil
            sidebar.container.sidebarView.renderNow()
            sidebar.container.layoutSubtreeIfNeeded()
            seed(services, show)
        }
        var answer: [String: JSONValue] = [
            "machine": .string(name),
            "cloudWorkspace": .bool(services.registry.context.contains(.cloudWorkspace)),
        ]
        guard let frame = sidebar.container.machineHeaderFrameInWindow(machine), let window = controller.window else {
            answer["header"] = .null
            return .object(answer)
        }
        answer["header"] = .array([.number(frame.minX), .number(frame.minY), .number(frame.width), .number(frame.height)])
        if params["menu"]?.boolValue == true {
            // `debug.mouse` takes top-left window points; the header's frame is bottom-left.
            let height = window.contentView?.bounds.height ?? window.frame.height
            answer["menu"] = DebugMouse.send(["x": .number(frame.midX), "y": .number(height - frame.midY), "button": .string("right"),
                                              "window": .string(controller.state.id)], services: services)
        }
        return .object(answer)
    }

    /// This Mac with one workspace, then the Cloud machine with one, so its header shows (one machine's
    /// header titles the list instead).
    private static func fixture(machine: MachineID, name: String) -> [SidebarSection] {
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let cloud = SidebarMachine(id: machine, name: name, kind: .cloud, status: .connected)
        return [
            SidebarSection(kind: .machine(local), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("w-local"), machineID: .local, title: "cmux"))]),
            SidebarSection(kind: .machine(cloud), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("w-cloud"), machineID: machine, title: "api"))]),
        ]
    }
}
#endif
