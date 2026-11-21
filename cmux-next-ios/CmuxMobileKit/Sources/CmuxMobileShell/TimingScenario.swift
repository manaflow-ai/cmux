#if DEBUG
import CmuxMobileModel
import Foundation
import OSLog

private let timingLog = Logger(subsystem: "dev.cmux.mobile", category: "timing")

/// A launch driver for the timing mode of `scripts/ci/cmux-next-ios-sim.sh` (DEBUG only): with
/// `CMUX_MOBILE_TIMING_SCENARIO` set, the app opens a tab of the paired Mac once its workspaces arrive,
/// as a tap on the workspace row with that tab does, so the run needs no UI driver.
///
/// - `terminal`: opens the first terminal tab it finds.
/// - `browser_then_terminal`: opens a browser tab, and `CMUX_MOBILE_TIMING_SWITCH_AFTER` seconds later
///   (default 3) the terminal tab of the same workspace (`timing event scenario_switch_to_terminal`).
///   The terminal's frame, and whether it ever said offline (`timing launch terminal_offline_shown`),
///   are read from the log next to `timing launch terminal_ready`.
///
/// Each event is logged once per process (`timing event scenario_...`).
@MainActor
final class TimingScenario {
    static let shared = TimingScenario()

    private let scenario = ProcessInfo.processInfo.environment["CMUX_MOBILE_TIMING_SCENARIO"]
    private let switchAfter = Double(ProcessInfo.processInfo.environment["CMUX_MOBILE_TIMING_SWITCH_AFTER"] ?? "") ?? 3
    private var opened = false

    var isOn: Bool { scenario == "terminal" || scenario == "browser_then_terminal" }

    /// Called whenever the workspaces change (`ShellModel.continueRestore`); acts once.
    func step(_ shell: ShellModel) {
        guard isOn, !opened else { return }
        let wantsBrowser = scenario == "browser_then_terminal"
        guard let workspace = shell.store.activeWorkspaces.first(where: { workspace in
            workspace.tabs.contains { $0.kind == .terminal } && (!wantsBrowser || workspace.tabs.contains { $0.kind == .browser })
        }), let terminal = workspace.tabs.first(where: { $0.kind == .terminal }) else { return }
        opened = true
        let first = wantsBrowser ? (workspace.tabs.first { $0.kind == .browser } ?? terminal) : terminal
        open(first, in: workspace, shell: shell)
        timingLog.info("timing event scenario_open_\(first.kind.rawValue, privacy: .public) (\(Int(ConnectTimeline.shared.sinceProcessStart * 1000), privacy: .public)ms)")
        guard wantsBrowser else { return }
        Task { @MainActor [switchAfter] in
            try? await Task.sleep(for: .seconds(switchAfter))
            open(terminal, in: workspace, shell: shell)
            ConnectTimeline.shared.event("scenario_switch_to_terminal")
        }
    }

    private func open(_ tab: WorkspaceTab, in workspace: Workspace, shell: ShellModel) {
        shell.store.requestOpen(tabID: tab.id, in: workspace.id)
        shell.show(workspace: workspace)
        if let live = shell.live, shell.store.teams.flatMap(\.macs).contains(where: { $0.id == workspace.macID && $0.isOnline }) {
            live.select(macID: workspace.macID)
        }
    }
}
#endif
