import class CmuxNextDesign.LaunchReveal
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import os
import CmuxNextWakeups

extension AgentTabStore {
    /// `install:<id>` of this Mac. Only that host attaches a tab to its acpmux; nil refuses new
    /// tabs. Read again while it is nil (the id file could not be read yet).
    var localHost: String? {
        get {
            if resolvedLocalHost == nil { resolvedLocalHost = resolveLocalHost() }
            return resolvedLocalHost
        }
        set { resolvedLocalHost = newValue }
    }

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

    /// At most four host batches warm at once; each host sends one session RPC at a time.
    static let launchResumesInFlight = 4

    /// Groups this Mac's restored chats by their recorded host, preserving tree order. A Chief
    /// router can resolve ownership from one fresh session census for the entire batch.
    private func resumeTargetsAtLaunch() -> [(sessions: [String], host: any AgentPaneHostProviding)] {
        guard let localHost else { return [] }
        var batches: [(sessions: [String], host: any AgentPaneHostProviding)] = []
        var indices: [String: Int] = [:], seen = Set<String>()
        for (key, record) in listTabs() {
            guard record.host == localHost ||
                (daemonForTab(key)?.isLocal != false && record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix)) else { continue }
            guard let session = sessions[resolve(key)] ?? record.session,
                  seen.insert(record.host + "\0" + session).inserted else { continue }
            if let index = indices[record.host] {
                batches[index].sessions.append(session)
                continue
            }
            let selectedHost: (any AgentPaneHostProviding)?
            if record.host == localHost {
                selectedHost = localSessionHost ?? host
            } else {
                selectedHost = chiefTabHost(record.host)
            }
            guard let selectedHost else { continue }
            indices[record.host] = batches.count
            batches.append(([session], selectedHost))
        }
        return batches
    }

    /// Warms every local host batch without constructing pages. Failed batches are retained for
    /// at most two retries, so a transient acpmux handoff does not depend on another tree mutation.
    /// Successful batches are never submitted again in this run.
    @discardableResult
    func resumeChatsAtLaunch(clock: any Clock<Duration> = ContinuousClock()) async -> Bool {
        guard !Task.isCancelled, localHost != nil else { return false }
        var pending = resumeTargetsAtLaunch()
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(2), jitter: 0)
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return false }
            if pending.isEmpty { return true }
            let targets = pending
            let failed = await withTaskGroup(of: Int?.self) { group in
                var next = 0, failures: [Int] = []
                func add(_ index: Int) {
                    let target = targets[index]
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            try await target.host.warm(sessionIds: target.sessions)
                            return nil
                        } catch {
                            if !Task.isCancelled {
                                Self.launchLogger.error("launch resume failed: \(String(describing: error), privacy: .public)")
                            }
                            return index
                        }
                    }
                }
                while next < min(Self.launchResumesInFlight, targets.count) { add(next); next += 1 }
                for await failure in group {
                    if let failure { failures.append(failure) }
                    guard !Task.isCancelled else { group.cancelAll(); continue }
                    if next < targets.count { add(next); next += 1 }
                }
                return failures.sorted()
            }
            guard !Task.isCancelled else { return false }
            pending = failed.map { targets[$0] }
            if pending.isEmpty { return true }
            guard attempt < 2 else { break }
            // concurrency-allow: bounded error backoff through an injected Clock; no readiness polling.
            do { try await backoff.wait(owner: "agent.launchResume", clock: clock) } catch { return false }
        }
        return false
    }

    /// Cancels launch work and drains its client requests before Quit's existing daemon shutdown
    /// fences agent creation. Cancellation closes the RPC socket; it does not undo an accepted RPC.
    func cancelLaunchResume() async {
        let task = launchResumeTask
        task?.cancel()
        await task?.value
        // Keep the cancelled task as the launch token: quit must not install another observer.
    }

    /// Waits for the confirmed local tree, then loads this Mac's identity off the main thread.
    /// One owner runs the launch operation; releasing the tab store or quitting cancels it.
    func resumeChatsWhenLoaded(_ store: DaemonStore, clock: any Clock<Duration> = ContinuousClock()) {
        guard launchResumeTask == nil else { return }
        // task-owner: AgentTabStore cancels in deinit; Quit cancels and drains before ending agents.
        launchResumeTask = Task { [weak self] in
            for await live in ObservationStream({ store.liveTabListRevision }) where live != nil {
                guard !Task.isCancelled else { return }
                var backoff = Backoff(initial: .seconds(1), maximum: .seconds(2), jitter: 0)
                for attempt in 0..<3 {
                    do {
                        // Do not retain the tab store while the background identity read waits.
                        let load = self?.loadLocalHostForLaunch
                        if let load {
                            let host = try await load()
                            try Task.checkCancellation()
                            self?.localHost = host
                        }
                        break
                    } catch {
                        guard !Task.isCancelled, attempt < 2 else { return }
                        // concurrency-allow: bounded error backoff after a failed identity read.
                        do { try await backoff.wait(owner: "agent.launchIdentity", clock: clock) } catch { return }
                    }
                }
                guard !Task.isCancelled else { return }
                guard store.liveTabListRevision != nil else { continue }
                _ = await self?.resumeChatsAtLaunch(clock: clock)
                return
            }
        }
    }
}
