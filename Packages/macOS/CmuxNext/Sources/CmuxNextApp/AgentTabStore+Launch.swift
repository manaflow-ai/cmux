import class CmuxNextDesign.LaunchReveal
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import os

extension AgentTabStore {
    /// What every chat holds for the next launch (the quit's window step).
    func relaunchWakeStates() async -> [String: AgentPaneWakeState] { await relaunchWake.collect(held: wakeStates, pages: views.map { (resolve($0.key), $0.value) }, live: isAgentTab) }

    /// Whether `key`'s view in `pane` waits for the launch's first pane
    /// content (the focused terminal's first frame, `LaunchSettle`; other
    /// content once shown; the reveal deadline). A tab's first web view
    /// (`WKProcessPool`, `AgentPaneView.init`) costs about 150 ms on the main
    /// thread and would delay the focused pane's terminal, so a tab outside
    /// the focused pane waits while that pane shows a terminal that will
    /// draw (`focusedDraws`); a focused tab, a focused terminal whose host
    /// ended, or a launch whose focus is not known yet makes its view at
    /// once. `show` runs once, when the content arrives; the pane keeps what
    /// it shows (the launch snapshot) meanwhile.
    func deferAtLaunch(_ key: String, reveal: LaunchReveal, focusedPane: String?, pane: String, focusedDraws: Bool,
                       show: @escaping @MainActor () -> Void) -> Bool {
        guard focusedDraws, !reveal.isReady(.pane), views[resolve(key)] == nil, let focusedPane, focusedPane != pane else {
            return false
        }
        guard launchDeferred.insert(key).inserted else { return true }
        reveal.whenReady(.pane) { [weak self] in
            self?.launchDeferred.remove(key)
            show()
        }
        return true
    }
}

extension AgentTabStore {
    nonisolated private static let launchLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-tabs")

    /// How many chats start their agent at once at launch.
    static let launchResumesInFlight = 4

    /// The sessions of this Mac's chat tabs in every workspace, once each, in tree order, paired
    /// with the acpmux that owns each session. Chief-home records are included only when their tab
    /// is listed by this Mac's local daemon; a remote machine's Chief record stays remote.
    private func resumeTargetsAtLaunch() -> [(session: String, host: any AgentPaneHostProviding)] {
        guard let localHost else { return [] }
        var seen = Set<String>()
        return listTabs().compactMap { key, record in
            // The restored tree already carries the durable session. A page may have reported a
            // newer session for this tab while its bind echo is still in flight; prefer that
            // observation, then fall back to the tree record so launch does not depend on a page
            // having been constructed.
            let session = sessions[resolve(key)] ?? record.session
            guard let session else { return nil }
            let listedHere = daemonForTab(key)?.isLocal != false
            let host: (any AgentPaneHostProviding)?
            if record.host == localHost {
                host = localSessionHost ?? self.host
            } else if listedHere, record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix) {
                host = chiefTabHost(record.host)
            } else {
                host = nil
            }
            guard let host, seen.insert(record.host + "\0" + session).inserted else { return nil }
            return (session: session, host: host)
        }
    }

    /// Starts the agent of every chat tab of this Mac at launch (cmux#22292): a chat's page, and
    /// with it its session, is made only when its tab shows, so the chats of a workspace not shown
    /// stayed stopped until it was. acpmux starts each one as the page would, with its own mode.
    func resumeChatsAtLaunch() async {
        let targets = resumeTargetsAtLaunch()
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var pending = targets.makeIterator()
            let warm: @Sendable ((session: String, host: any AgentPaneHostProviding)) async -> Void = { target in
                do {
                    try await target.host.warm(sessionIds: [target.session])
                } catch {
                    Self.launchLogger.error("launch resume of chat \(target.session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            for target in targets.prefix(Self.launchResumesInFlight) {
                _ = pending.next()
                group.addTask { await warm(target) }
            }
            for await _ in group {
                if let target = pending.next() { group.addTask { await warm(target) } }
            }
        }
    }

    /// Resumes every chat once `store` (this Mac's tree) first loads.
    func resumeChatsWhenLoaded(_ store: DaemonStore) {
        guard launchResumeTask == nil else { return }
        // task-owner: retained by the tab store and cancelled in deinit, including before connect.
        launchResumeTask = Task { [weak self] in
            for await live in ObservationStream({ store.liveTabListRevision }) where live != nil {
                guard !Task.isCancelled else { return }
                await self?.resumeChatsAtLaunch()
                return
            }
        }
    }
}
