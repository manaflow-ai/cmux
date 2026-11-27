import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextTabs
import Foundation
import Testing

/// A chat of this Mac's normal window and an incognito chat on an SSH machine share a tab id (a
/// forked machine keeps its tab ids). The quit reads each chat's window on its own machine, so the
/// SSH machine's incognito composer is never written for the next launch (#36767; leo-workspace
/// design/spaces.md "Incognito").
@MainActor @Suite(.serialized)
struct AgentQuitIncognitoMachinesTests {
    @Test func theQuitLeavesOutAnotherMachinesIncognitoChatOfTheSameID() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@lab.tail1.ts.net")).named("lab")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-quit-incognito-remote-unused")),
                                    environment: { [:] }, mainWork: services.mainWork)
        services.machines.add(ssh)
        let window = services.windows.newIncognitoWindow()
        let secret = WorkspaceKey(rawValue: try #require(services.windows.claims.pending.first { $0.value == window }?.key))
        func tree(_ key: WorkspaceKey) -> DaemonTree {
            let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_forked", title: "chat")])
            return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: key, name: key.rawValue, screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])])
        }
        services.daemon.store.apply(snapshot: tree(WorkspaceKey.generate()))
        ssh.daemon.store.apply(snapshot: tree(secret))

        let directory = FileManager.default.temporaryDirectory.appending(path: "quit-incognito-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabs = services.agentTabs
        tabs.relaunchWake = AgentPaneRelaunchWake(file: directory.appending(path: AgentPaneRelaunchWake.fileName))
        let here = AgentTabKey(machine: services.daemon.machineID, key: "tab_forked")
        let lab = AgentTabKey(machine: ssh.machineID, key: "tab_forked")
        let records = DaemonStore()
        tabs.lookupScoped = { key in
            [here, lab].contains(key) ? (AgentSessionRef(host: "install:quit-incognito-test", hostName: "This Mac", session: "s-\(key.machine)", harness: "claude"), records) : nil
        }
        tabs.wakeStates[here] = AgentPaneWakeState(shell: true, shellText: "make test")
        tabs.wakeStates[lab] = AgentPaneWakeState(shell: true, shellText: "cat ~/.ssh/id_ed25519")

        // What the quit's prepareWindows step does (QuitCoordinator.quitSteps).
        let incognito = AgentQuitFiles.incognitoTabs(tabs, isIncognito: { AgentQuitFiles.isIncognito($0, in: services) })
        let saved = await AgentQuitFiles.composers(tabs, isIncognito: { AgentQuitFiles.contains(incognito, $0) })
        #expect(saved.values.compactMap(\.shellText) == ["make test"], "the quit wrote the wrong composers: \(saved)")
    }
}
