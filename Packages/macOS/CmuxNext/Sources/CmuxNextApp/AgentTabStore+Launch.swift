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
    /// Returns `false` when this Mac's install host is not available yet. The launch observer keeps
    /// listening for another live-tree revision in that case; the Cloud install id can finish its
    /// first read just after the daemon's first snapshot.
    @discardableResult
    func resumeChatsAtLaunch() async -> Bool {
        guard localHost != nil else { return false }
        let targets = resumeTargetsAtLaunch()
        guard !targets.isEmpty else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            var pending = targets.makeIterator()
            let warm: @Sendable ((session: String, host: any AgentPaneHostProviding)) async -> Bool = { target in
                do {
                    try await target.host.warm(sessionIds: [target.session])
                    return true
                } catch {
                    Self.launchLogger.error("launch resume of chat \(target.session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    return false
                }
            }
            for target in targets.prefix(Self.launchResumesInFlight) {
                _ = pending.next()
                group.addTask { await warm(target) }
            }
            var allSucceeded = true
            for await succeeded in group {
                allSucceeded = allSucceeded && succeeded
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let target = pending.next() { group.addTask { await warm(target) } }
            }
            // A transient daemon handoff can reject a warm request. Keep the observer alive so
            // the next live-tree revision retries the complete idempotent census.
            return allSucceeded
        }
    }

    /// Stops launch warming before Quit ends local agents or terminals, and waits for any in-flight
    /// request to finish so it cannot restart a daemon after the quit choice took effect.
    func cancelLaunchResume() async {
        let task = launchResumeTask
        launchResumeTask = nil
        task?.cancel()
        await task?.value
    }

    /// Resumes every chat once `store` (this Mac's tree) first loads.
    func resumeChatsWhenLoaded(_ store: DaemonStore) {
        guard launchResumeTask == nil else { return }
        // task-owner: retained by the tab store and cancelled in deinit, including before connect.
        launchResumeTask = Task { [weak self] in
            for await live in ObservationStream({ store.liveTabListRevision }) where live != nil {
                guard !Task.isCancelled else { return }
                for retry in 0..<3 {
                    if await self?.resumeChatsAtLaunch() == true { return }
                    guard !Task.isCancelled else { return }
                    guard retry < 2 else { break }
                    // wakeup-allow: bounded launch recovery backoff for a daemon handoff; this
                    // task is off the main thread and cancellation stops the retry before quit.
                    try? await Task.sleep(for: .seconds(1 << retry))
                }
            }
        }
    }
}
