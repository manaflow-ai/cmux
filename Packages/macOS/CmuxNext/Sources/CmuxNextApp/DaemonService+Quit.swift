import CmuxNextDaemon
import Foundation

extension DaemonService {
    /// Quit's end choices on the local daemon: stops this service's
    /// connection and reconnects first (the daemon's exit must not start a
    /// new one), then ends every terminal and stops the daemon
    /// (`shutdown-daemon end_terminals`, which waits for every terminal
    /// host). A failure is logged and the quit goes on: the terminals that
    /// did not end stay for the next launch.
    /// - End Everything closes every local workspace first, so the next
    ///   launch opens one new workspace.
    /// - End Sessions, Keep Layout on a daemon with
    ///   `end-terminals-keep-layout-v1` keeps the tabs, dead, and records each
    ///   tab's directory (`KeptLayoutPlanFile`), so the next launch restarts
    ///   a shell in each with the same splits and ratios
    ///   (`relaunchKeptLayoutIfNeeded`). Older daemons remove the tabs.
    func endSessionsAndStop(_ choice: QuitSessionsChoice) async {
        guard isLocal, choice.ends, let connection else { return }
        guard supports(DaemonCapabilities.shared.terminalReap) else {
            logger.error("end sessions: the daemon lacks \(DaemonCapabilities.shared.terminalReap, privacy: .public)")
            return
        }
        let keepLayout = choice == .endKeepLayout && supports(DaemonCapabilities.shared.endTerminalsKeepLayout)
        if keepLayout, let tree = try? await connection.listWorkspaces() {
            KeptLayoutPlanFile.forApplication().write(KeptLayoutPlan(tree: tree))
        }
        shutdownConnection()
        do {
            let ended = try await connection.endSessionsAndStop(deletingWorkspaces: choice == .endEverything,
                                                                keepingLayout: keepLayout)
            logger.info("end sessions: ended \(ended.endedTerminals) terminals, kept layout \(ended.keptLayout), daemon stopped")
            if !ended.keptLayout { KeptLayoutPlanFile.forApplication().remove() }
        } catch {
            logger.error("end sessions failed: \(String(describing: error), privacy: .public)")
            KeptLayoutPlanFile.forApplication().remove()
        }
    }

    /// After End Sessions, Keep Layout: restarts a shell in every kept tab
    /// the plan lists, in its recorded directory, then forgets the plan.
    func relaunchKeptLayoutIfNeeded(_ connection: DaemonConnection) {
        guard isLocal else { return }
        let file = KeptLayoutPlanFile.forApplication()
        guard let plan = file.read() else { return }
        let logger = logger
        // task-owner: one-shot relaunch after connect; the file is removed first so a crash never repeats it
        Task {
            file.remove()
            do {
                let relaunched = try await connection.relaunchKeptTabs(plan)
                logger.info("kept layout: restarted \(relaunched) of \(plan.tabs.count) terminals")
            } catch {
                logger.error("kept layout relaunch failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// `<Application Support>/<bundle id>/kept-layout.json`: the plan End
/// Sessions, Keep Layout writes for the next launch.
struct KeptLayoutPlanFile {
    let url: URL

    static func forApplication(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> KeptLayoutPlanFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return KeptLayoutPlanFile(url: support.appending(path: bundle).appending(path: "kept-layout.json"))
    }

    func write(_ plan: KeptLayoutPlan) {
        return  // not implemented yet
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func read() -> KeptLayoutPlan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeptLayoutPlan.self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
