#if DEBUG
import CmuxNextBridge
import CmuxNextControl
import CmuxNextSettings
import CmuxNextSidebar
import Foundation

/// `debug.chief_workspaces`: the Chief's sidebar group in a capture (DEV builds only; this file is
/// compiled out of release builds, `tests/test_cmux_next_debug_only_controls.py`). A capture slot
/// has the Chief owner the app starts, but nothing there starts subagents, so its group is empty
/// and draws nothing. This opens named workspaces on the local Chief machine through the same
/// path as a sidebar machine's New Workspace (`createWorkspace(on:)`), folds its group, and shows
/// a row's hover card.
///
/// Params, each optional: `open: [name]` opens them (waits up to 30 s for the Chief owner), each
/// running `command` when given (a capture's still must not show the mini's shell prompt);
/// `collapse: Bool` folds or opens the Chief group in the active window; `card: Int` shows the
/// hover card of the opened workspace at that index. Answers the opened workspace ids.
enum ChiefCaptureControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .async("debug.chief_workspaces") { [weak services] call in
                guard let services else { throw ControlError(code: "unavailable", message: "no services") }
                let names = (call.params["open"]?.arrayValue ?? []).compactMap(\.stringValue)
                let command = call.params["command"]?.stringValue
                guard let chief = await localChief(services) else {
                    throw ControlError(code: "unavailable", message: "no local Chief machine connected within 30 s")
                }
                let machineID = await MainActor.run { chief.machineID }
                var ids: [String] = []
                for name in names {
                    let window = await MainActor.run { services.windows.targetWindow(preferring: services.windows.active?.state.id) }
                    ids.append(try await services.windows.createWorkspace(WorkspaceSpawn(name: name, command: command), on: chief.daemon, into: window))
                }
                if let collapse = call.params["collapse"]?.boolValue {
                    try await MainActor.run { try fold(services, chief: machineID, collapse: collapse) }
                }
                if let index = call.params["card"]?.intValue {
                    guard ids.indices.contains(index) else { throw ControlError.invalidParams("card names no opened workspace") }
                    try await MainActor.run { try showCard(services, workspace: ids[index]) }
                }
                return .object(["machine": .string(machineID), "workspaces": .array(ids.map(JSONValue.string))])
            }.withDeadline(.fixed(.seconds(60))),
        ]
    }

    /// The local Chief machine once its daemon is connected; nil after 30 s.
    @MainActor
    private static func localChief(_ services: AppServices) async -> ServerMachineSession? {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let chief = services.machines.servers.first(where: { $0.reach.isLocalChief && $0.isConnected }) { return chief }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    @MainActor
    private static func fold(_ services: AppServices, chief: String, collapse: Bool) throws {
        guard let sidebar = services.windows.active?.sidebar else { throw ControlError(code: "unavailable", message: "no active window") }
        let section = CmuxNextSidebar.SectionID.machine(CmuxNextSidebar.MachineID(chief))
        guard let shown = sidebar.model.section(section) else { throw ControlError(code: "unavailable", message: "the Chief group is not in the sidebar") }
        if shown.isCollapsed != collapse { sidebar.handle(.toggleCollapse(.section(section))) }
    }

    @MainActor
    private static func showCard(_ services: AppServices, workspace: String) throws {
        guard let window = services.windows.active,
              window.sidebar.container.sidebarView.showHoverCard(for: SidebarWorkspaceID(workspace)) else {
            throw ControlError(code: "unavailable", message: "the workspace's row is not shown")
        }
    }
}

private extension ServerMachineSession {
    var isConnected: Bool {
        if case .connected = daemon.store.connectionState { true } else { false }
    }
}
#endif
