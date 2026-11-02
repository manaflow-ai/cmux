@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/31490: a new window listed every other window's
/// "Connecting to <host>…" rows for SSH machines that were reconnecting. A connecting row now
/// lists in one window only: the window that asked for the connect, else the oldest open
/// window, so a window opened later starts clean (as https://github.com/manaflow-ai/cmux/issues/26632 asks).
@MainActor @Suite struct SSHConnectingRowsWindowTests {
    static func connectingSession(_ text: String) throws -> SSHMachineSession {
        let host = try SSHHost(destination: SSHDestination(parsing: text), session: RemoteSessionName.defaultName)
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/ssh-connecting-rows-tests")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        session.linkStatus = .connecting
        return session
    }

    static func machines(_ sessions: [SSHMachineSession]) -> MachineRegistry {
        let machines = MachineRegistry(local: DaemonService())
        for session in sessions { machines.add(session) }
        return machines
    }

    static func rowTitles(_ sections: [SidebarRowSection]) -> [String] {
        sections.flatMap(\.workspaces).map(\.title)
    }

    @Test func aNewWindowListsNoReconnectingMachine() throws {
        let tailnet = try Self.connectingSession("100.127.99.33")
        let devbox = try Self.connectingSession("cmux-austin-devbox")
        let machines = Self.machines([tailnet, devbox])
        let open = ["window-1", "window-2"]

        let first = SSHConnectingRows.adding(machines, to: [], window: "window-1", windows: ConnectingRowWindows(open: open, incognito: { _ in false }, making: "window-1"))
        #expect(Self.rowTitles(first).count == 2, "the oldest window keeps the reconnecting machines' rows")
        let second = SSHConnectingRows.adding(machines, to: [], window: "window-2", windows: ConnectingRowWindows(open: open, incognito: { _ in false }, making: "window-2"))
        #expect(second.isEmpty, "a new window lists none of them")
        let making = SSHConnectingRows.adding(machines, to: [], window: "window-3", windows: ConnectingRowWindows(open: open, incognito: { _ in false }, making: "window-3"))
        #expect(making.isEmpty, "nor does a window still being made")
    }

    @Test func aConnectListsInTheWindowThatAskedForIt() throws {
        let asked = try Self.connectingSession("leo@studio")
        asked.connectingWindow = "window-2"
        let machines = Self.machines([asked])
        let open = ["window-1", "window-2"]

        #expect(SSHConnectingRows.adding(machines, to: [], window: "window-1", windows: ConnectingRowWindows(open: open, incognito: { _ in false }, making: "window-1")).isEmpty)
        #expect(Self.rowTitles(SSHConnectingRows.adding(machines, to: [], window: "window-2", windows: ConnectingRowWindows(open: open, incognito: { _ in false }, making: "window-2"))).count == 1)

        // The asking window closed: the oldest open window takes the row.
        #expect(Self.rowTitles(SSHConnectingRows.adding(machines, to: [], window: "window-1", windows: ConnectingRowWindows(open: ["window-1"], incognito: { _ in false }, making: "window-1"))).count == 1)
    }

    @Test func theLaunchWindowListsTheRowBeforeItsControllerIs() throws {
        let machines = Self.machines([try Self.connectingSession("leo@studio")])
        let rows = SSHConnectingRows.adding(machines, to: [], window: "launch", windows: ConnectingRowWindows(open: [], incognito: { _ in false }, making: "launch"))
        #expect(Self.rowTitles(rows).count == 1)
    }

    @Test func theOwnerIsTheAskingWindowWhileOpenElseTheOldest() {
        let windows = ConnectingRowWindows(open: ["a", "b"], incognito: { _ in false }, making: nil)
        #expect(windows.owner(requestedBy: "b") == "b")
        #expect(windows.owner(requestedBy: "gone") == "a")
        #expect(windows.owner(requestedBy: nil) == "a")
        #expect(ConnectingRowWindows(open: [], incognito: { _ in false }, making: nil).owner(requestedBy: nil) == nil)
        #expect(ConnectingRowWindows(open: ["a"], incognito: { _ in false }, making: "new").owner(requestedBy: nil) == "a", "a window being made comes last")
        #expect(ConnectingRowWindows(open: ["private", "a"], incognito: { $0 == "private" }, making: nil).owner(requestedBy: nil) == "a",
                "an incognito window takes no row while a normal window is open")
        #expect(ConnectingRowWindows.machine(of: ConnectingRowWindows.prefix + "m1") == "m1")
        #expect(ConnectingRowWindows.machine(of: "ws_1") == nil)
    }
}
