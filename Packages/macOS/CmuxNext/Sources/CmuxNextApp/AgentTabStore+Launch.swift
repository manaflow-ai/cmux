import class CmuxNextDesign.LaunchReveal
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import os

extension AgentTabStore {
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

    /// The sessions of this Mac's chat tabs in every workspace, once each, in tree order: what a
    /// relaunch resumes (``resumeChatsAtLaunch()``). Another machine's chats run there.
    func sessionsToResume() -> [String] {
        guard let localHost else { return [] }
        var seen = Set<String>()
        return listTabs().compactMap { key, record in
            guard record.host == localHost, let session = session(of: key), seen.insert(session).inserted else { return nil }
            return session
        }
    }

    /// Starts the agent of every chat tab of this Mac at launch (cmux#22292): a chat's page, and
    /// with it its session, is made only when its tab shows, so the chats of a workspace not shown
    /// stayed stopped until it was. acpmux starts each one as the page would, with its own mode.
    func resumeChatsAtLaunch() async {
        let sessions = sessionsToResume()
        guard !sessions.isEmpty else { return }
        let host = localSessionHost ?? host
        await withTaskGroup(of: Void.self) { group in
            var pending = sessions.makeIterator()
            let warm: @Sendable (String) async -> Void = { session in
                do {
                    try await host.warm(sessionIds: [session])
                } catch {
                    Self.launchLogger.error("launch resume of chat \(session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            for session in sessions.prefix(Self.launchResumesInFlight) {
                _ = pending.next()
                group.addTask { await warm(session) }
            }
            for await _ in group {
                if let session = pending.next() { group.addTask { await warm(session) } }
            }
        }
    }

    /// Resumes every chat once `store` (this Mac's tree) first loads.
    func resumeChatsWhenLoaded(_ store: DaemonStore) {
        // task-owner: ends after the one resume; the store outlives the app's launch
        Task { [weak self] in
            for await live in ObservationStream({ Self.liveTabs(store) }) where live != nil {
                await self?.resumeChatsAtLaunch()
                return
            }
        }
    }
}
