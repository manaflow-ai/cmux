@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The launch's classic run parks the terminals of the workspaces it brings
/// over in the background (`park-tabs`), whatever state each terminal is in
/// when the run reaches it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicUpgradeParkTests {
    /// A background workspace with a terminal that ended before the run reached
    /// it is still parked: its other terminal stops and starts on first show.
    /// Before, the run waited up to 5 s for every terminal to show running,
    /// gave up without a word and left the other shell running.
    @Test func aBackgroundWorkspaceWithAnEndedTerminalIsStillParked() async throws {
        let mac = try ClassicUpgradeSimulator.Mac()
        let ends = mac.root.appendingPathComponent("ends-at-once", isDirectory: true)
        try FileManager.default.createDirectory(at: ends, withIntermediateDirectories: true)
        // The daemon's shell: it exits at once in `ends`, and is /bin/sh everywhere else.
        let shell = mac.root.appendingPathComponent("shell.sh")
        try Data("#!/bin/sh\ncase \"$(pwd -P)\" in *ends-at-once*) exit 0 ;; esac\nexec /bin/sh \"$@\"\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let profile = ClassicUpgradeProfile(name: "endedTerminal", windows: [ClassicUpgradeProfile.Window(workspaces: [
            ClassicUpgradeProfile.Workspace(title: "front"),
            ClassicUpgradeProfile.Workspace(title: "mixed", layout: .pane([.terminal(), .terminal(folder: ends.path)])),
        ], selected: 0)])
        try mac.save(profile)
        let sim = try ClassicUpgradeSimulator(mac: mac, shell: shell.path)
        let launch = await sim.launch()
        #expect(launch.failure == nil, "\(String(describing: launch.failure))")
        await sim.settle()
        let store = sim.services.daemon.store
        let mixed = try #require(store.workspaces.first { $0.name == "mixed" }).id
        let tabs = { store.workspace(id: mixed)?.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty } ?? [] }
        // `park-tabs` answers before the shells exit: a parked tab shows dead with `relaunch` once its host
        // exited. A ceiling for that, not a budget.
        let parked = { tabs().allSatisfy { $0.dead } && tabs().contains { $0.relaunch?.onShow == true } }
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline, !parked() { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(parked(), "not parked: \(tabs().map { ($0.dead, $0.relaunch?.onShow) })")
        await sim.shutdown()
    }
}
