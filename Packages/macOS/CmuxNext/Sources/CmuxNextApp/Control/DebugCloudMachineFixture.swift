#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.cloud_machine_fixture {sidebar?, fill?, menu?, folder?, name?, status?, detail?, window?}` (DEBUG builds, captures of a Cloud
/// machine's right-click menu). A capture slot is signed out of cmux Cloud and has no Cloud machine,
/// so a Cloud machine header's menu there hides every row that needs `cloudWorkspace` (its Tools
/// folder's Apply Machine Config and Deliver Secrets among them), and no menu change could show a
/// before and after. A real machine would cost money and show account names.
/// - `sidebar: true`: the window's sidebar shows a fixture This Mac and a Cloud machine named `name`
///   (default `demo-cloud`), a section each, and the action registry holds `cloudWorkspace` as it
///   does while a Cloud machine's workspace is active (``seed(_:)``); `false` brings the live rows
///   and context back. The machine is a sidebar row and nothing else: no session, no sign-in, no
///   network call, no Cloud state.
/// - `fill: true`: the window takes its screen's visible height, at its own width (a folder of 20
///   rows is taller than the default window, and a capture is cut to the window). Its own step, so
///   the header is laid out at the new size before `menu`.
/// - `backend: true`: Cloud reads as reachable though the build has no Cloud backend or client
///   (``CloudService/debugBackendFixture``), so signed-out Cloud rows show their sign-in state; `false` ends it.
/// - `menu: true`: a right-click on that header (`debug.mouse`), so its menu opens as the person's
///   does (`SidebarContextMenus.machineMenu`).
/// - `folder: "Tools"`: with that menu open, types the folder's title (the menu's type-select) and
///   the right arrow, so the folder opens. The keys go to the app's event queue, which the open
///   menu reads; `debug.key`'s sequence needs an event source a capture slot does not give.
/// Answers the machine id, whether the registry holds `cloudWorkspace`, and the header's frame.
@MainActor
enum DebugCloudMachineFixture {
    /// The fixture machine's id when the call names none.
    static let defaultName = "demo-cloud"

    /// The fixture accepts the sidebar's status names plus `starting`, which is the
    /// Cloud API spelling for the sidebar's `resuming` state. Keeping this mapping
    /// here makes capture inputs explicit and rejects typos instead of silently
    /// rendering the connected state.
    static func parseStatus(_ raw: String?) -> SidebarMachine.Status? {
        guard let raw else { return .connected }
        switch raw {
        case "connected": return .connected
        case "connecting": return .connecting
        case "reconnecting": return .reconnecting
        case "offline": return .offline
        case "update-available", "updateAvailable": return .updateAvailable
        case "update-required", "updateRequired": return .updateRequired
        case "install-required", "installRequired": return .installRequired
        case "installing": return .installing
        case "auth-failed", "authFailed": return .authFailed
        case "unreachable": return .unreachable
        case "failed": return .failed
        case "paused": return .paused
        case "paused-idle", "pausedIdle": return .pausedIdle
        case "pausing": return .pausing
        case "starting", "resuming": return .resuming
        case "deleting": return .deleting
        default: return nil
        }
    }

    /// Holds (or, `false`, drops) `cloudWorkspace` in `services`' registry context, as a Cloud machine's
    /// active workspace does, without a session or a sign-in: only in that app's ``AppServices/DebugFixtures``, never
    /// another's (tests build their own), and DEBUG only, so a Release build never holds it.
    static func seed(_ services: AppServices, _ on: Bool = true) {
        services.debugFixtures.holdsCloudWorkspace = on
        services.cloudContextDidChange()
    }

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let name = params["name"]?.stringValue ?? defaultName
        guard let status = parseStatus(params["status"]?.stringValue) else {
            return .object(["error": .string("invalid cloud machine status: \(params["status"]?.stringValue ?? "")")])
        }
        let detail = params["detail"]?.stringValue
        let machine = MachineID(name)
        guard let controller = services.windows.controllers.first(where: { c in params["window"]?.stringValue.map { $0 == c.state.id } ?? true })
                ?? services.windows.active else {
            return .object(["error": .string("no window")])
        }
        let sidebar = controller.sidebar
        if let backend = params["backend"]?.boolValue { services.cloud.debugBackendFixture = backend }
        if let show = params["sidebar"]?.boolValue {
            // Machine headers are drawn only with a section per computer (`sidebar.groupByComputer`).
            DesignSettings.shared.sidebarSections.groupsByComputer = show
                || (services.settings?.snapshot.sidebarSections ?? .defaults).groupsByComputer
            sidebar.rows.fixture = show ? fixture(machine: machine, name: name, status: status, detail: detail) : nil
            sidebar.container.sidebarView.renderNow()
            sidebar.container.layoutSubtreeIfNeeded()
            seed(services, show)
        }
        var answer: [String: JSONValue] = [
            "machine": .string(name),
            "cloudWorkspace": .bool(services.registry.context.contains(.cloudWorkspace)),
        ]
        if params["fill"]?.boolValue == true, let window = controller.window, let screen = window.screen {
            let visible = screen.visibleFrame
            window.setFrame(NSRect(x: window.frame.minX, y: visible.minY, width: window.frame.width, height: visible.height), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
        }
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
        if let folder = params["folder"]?.stringValue {
            let events = folderKeys(folder, window: window)
            events.forEach { NSApp.postEvent($0, atStart: false) }
            answer["folderKeys"] = .number(Double(events.count))
        }
        return .object(answer)
    }

    /// An open menu's keys for `title`: each letter (type-select), then the right arrow, down and up.
    static func folderKeys(_ title: String, window: NSWindow) -> [NSEvent] {
        // ANSI key codes 0 to 47 by character (10 and 36 have none here).
        let codes = Array("asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm.")
        var keys = title.lowercased().map { (String($0), UInt16(codes.firstIndex(of: $0) ?? 49), NSEvent.ModifierFlags()) }
        keys.append((FunctionKeyCharacter.string(NSRightArrowFunctionKey), 124, [.numericPad, .function]))
        return keys.flatMap { characters, code, flags in
            [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            }
        }
    }

    /// This Mac with one workspace, then the Cloud machine with one, so its header shows (one machine's
    /// header titles the list instead).
    private static func fixture(machine: MachineID, name: String, status: SidebarMachine.Status,
                                detail: String?) -> [SidebarSection] {
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let cloud = SidebarMachine(id: machine, name: name, kind: .cloud, status: status, detail: detail)
        return [
            SidebarSection(kind: .machine(local), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("w-local"), machineID: .local, title: "cmux"))]),
            SidebarSection(kind: .machine(cloud), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("w-cloud"), machineID: machine, title: "api"))]),
        ]
    }
}
#endif
