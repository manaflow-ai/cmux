import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import os

/// Which persistent profile has loaded the built-in extensions (the bundled uBlock Origin), which one
/// loads them now, and which tab may ask for its browser. Through `--load-extension` they loaded at
/// Chromium's start, from the app's launch on: an idle app with no browser tab ran uBlock Origin's
/// background page in an extension renderer of its own (about 74 MB, decision d-e4f491bbb4). They now
/// load at each profile's first tab; ``CEFBuiltInExtensionLoader`` runs the loads.
nonisolated struct CEFBuiltInExtensionLoads: Equatable, Sendable {
    /// What a tab does before its browser is asked for.
    nonisolated enum Gate: Equatable, Sendable {
        /// Ask for it now: the profile has the folders, or loads none.
        case open
        /// The profile's first tab: load these folders, then ask once they answered.
        case start([String])
        /// The profile's load runs: ask once it answered.
        case waiting
    }

    /// The folders each first tab loads; empty: they loaded at start, or none is on.
    private(set) var folders: [String] = []
    /// This Chromium's loads by context key: how many folders have not answered yet (0: answered).
    private var unanswered: [String: Int] = [:]
    /// Counts Chromium starts, so the answer of an earlier Chromium's load changes nothing.
    private(set) var generation = 0

    /// A Chromium start: `folders` load at first tabs, into no profile yet.
    mutating func started(folders: [String]) {
        self.folders = folders
        unanswered = [:]
        generation += 1
    }

    /// Before a tab of `key` (context `contextKey`) asks for its browser. An incognito store never
    /// waits: cmux runs no extension there (browser.md "Extensions in incognito").
    mutating func gate(_ key: CEFPaneKey, contextKey: String) -> Gate {
        guard !folders.isEmpty, !key.offTheRecord else { return .open }
        switch unanswered[contextKey] {
        case nil:
            unanswered[contextKey] = folders.count
            return .start(folders)
        case 0?:
            return .open
        default:
            return .waiting
        }
    }

    /// True when the profile of `contextKey` may open its tabs now (its loads answered, or none runs).
    func isOpen(contextKey: String) -> Bool {
        (unanswered[contextKey] ?? 0) == 0
    }

    /// One folder's load into `contextKey` answered (loaded or not) in Chromium `generation`: true when
    /// it was the profile's last, so its waiting tabs ask for their browsers now.
    mutating func answered(contextKey: String, generation: Int) -> Bool {
        guard generation == self.generation, let left = unanswered[contextKey], left > 0 else { return false }
        unanswered[contextKey] = left - 1
        return left == 1
    }
}

/// Loads the built-in extensions into each persistent profile right before its first browser tab, and
/// holds that profile's tabs until the loads answered (one per runtime, ``CEFRuntime/builtInLoader``).
///
/// Chrome loads `--load-extension` folders at a profile's start "to avoid a race between extension
/// loading and loading an URL from the command line" (extensions/browser/unpacked_installer.cc). cmux
/// keeps that order later: the fork's `cmux_ext_load_command_line_async` reads the folder off the UI
/// thread and answers once Chrome installed the extension and its background page finished its first
/// load, so its webRequest listeners exist. The profile's first tab asks for its browser only after that
/// answer (`CEFPaneHost.ensureCreated`): `create_window` and `tab_add` navigate in the call, so no page
/// of the profile loads before the blocker. A fork without the call loads them at start, as before.
final class CEFBuiltInExtensionLoader {
    /// How long a load may take before the profile's tabs open without it (a fork that never answers
    /// must not leave every browser pane blank). Logged as an error when it passes.
    static let timeout: Duration = .seconds(10)

    /// Where this Chromium's built-in extensions load.
    nonisolated enum Placement: String, Equatable, Sendable {
        /// Into each persistent profile right before its first browser tab.
        case atFirstTab = "at_first_tab"
        /// On `--load-extension`: into every profile Chromium starts (a fork without the later load).
        case atStart = "at_start"
        /// No built-in folder to load (the setting off, or the person's own copy of it).
        case nothing = "none"
    }

    private struct Pending {
        let context: String
        let generation: Int
        let deadline: DemandTimer
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")
    private let clock: any Clock<Duration>
    private(set) var loads = CEFBuiltInExtensionLoads()
    /// The last start's placement (`.nothing` before Chromium started).
    private(set) var placement: Placement = .nothing
    /// The tabs' resumes waiting for their profile's load, by context key.
    private var waiters: [String: [() -> Void]] = [:]
    /// Each folder's load waiting for the fork's answer, by its reply id.
    private var pending: [Int32: Pending] = [:]

    /// Makes a profile's cache directory (CEF refuses a request context whose directory is missing), off
    /// the main thread, then runs `then` on it. Tests swap in one that runs `then` at once.
    var prepareContext: (String, @escaping @MainActor @Sendable () -> Void) -> Void = { context, then in
        Task.detached(priority: .userInitiated) {
            try? FileManager.checked.createDirectory(at: URL(filePath: context), withIntermediateDirectories: true)
            MainDelivery().run(then)
        }
    }

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// A Chromium start: where `folders` load. At each profile's first tab on a fork with the later
    /// load, else at start. A tab that waited for a previous Chromium's load asks again, against this one.
    @discardableResult
    func begin(_ folders: [String], forkSupports: Bool) -> Placement {
        placement = folders.isEmpty ? .nothing : forkSupports ? .atFirstTab : .atStart
        loads.started(folders: placement == .atFirstTab ? folders : [])
        for load in pending.values { load.deadline.cancel() }
        pending.removeAll()
        let waiting = waiters.values.flatMap { $0 }
        waiters.removeAll()
        for resume in waiting { resume() }
        return placement
    }

    /// Whether `tab`'s browser may be asked for now. The first tab of a persistent profile starts the
    /// load of the built-in extensions; it and every tab of the profile that asks meanwhile wait, and
    /// `resume` runs once, when the profile's last load answers (or its deadline passes). A placeholder
    /// (the spare window's, a popup host's) never waits and loads nothing: it shows no page.
    func ready(for tab: CEFTab, in host: CEFPaneHost, resume: @escaping () -> Void) -> Bool {
        guard !loads.folders.isEmpty, !host.key.offTheRecord, host.placeholder !== tab else { return true }
        let context = host.runtime.contextKey(for: host.key)
        let gate = loads.gate(host.key, contextKey: context)
        if case .start(let folders) = gate { load(folders, into: context, runtime: host.runtime) }
        // A load the shim refused at once (a test's synchronous `prepareContext`) answered in `load`.
        guard !loads.isOpen(contextKey: context) else { return true }
        waiters[context, default: []].append(resume)
        return false
    }

    /// A CMUX_SHIM_REPLY: true when it answers one of the loads (1: the extension is in).
    func answer(reply id: Int32, value: Int64) -> Bool {
        guard pending[id] != nil else { return false }
        finish(id, loaded: value == 1)
        return true
    }

    /// Starts one load per folder, each answered by a CMUX_SHIM_REPLY under its own reply id (from the
    /// site replies' ids, so the two never meet). The deadlines run from here; the shim is asked once the
    /// profile's directory exists, unless a new Chromium start or a deadline ended the load first.
    private func load(_ folders: [String], into context: String, runtime: CEFRuntime) {
        let generation = loads.generation
        var asks: [(id: Int32, folder: String)] = []
        for folder in folders {
            let id = runtime.nextSiteReply
            runtime.nextSiteReply = id == .max ? 1 : id + 1
            let deadline = DemandTimer(owner: "CEFBuiltInExtensionLoader.load", clock: clock)
            pending[id] = Pending(context: context, generation: generation, deadline: deadline)
            deadline.schedule(after: Self.timeout) { @MainActor [weak self] in
                guard let self, self.pending[id] != nil else { return }
                self.logger.error("built-in extension load did not answer in \(Self.timeout, privacy: .public); the profile's tabs open")
                self.finish(id, loaded: false)
            }
            asks.append((id, folder))
        }
        prepareContext(context) { [weak self, weak runtime] in
            guard let self else { return }
            for ask in asks where self.pending[ask.id] != nil {
                let started = context.withCString { key in ask.folder.withCString { runtime?.shim?.extLoadCommandLine?(key, ask.id, $0) } } ?? 0
                if started != 1 { self.finish(ask.id, loaded: false) }
            }
        }
    }

    /// Ends load `id` once (its answer, its refused start or its deadline); the profile's last load
    /// wakes its waiting tabs.
    private func finish(_ id: Int32, loaded: Bool) {
        guard let load = pending.removeValue(forKey: id) else { return }
        load.deadline.cancel()
        if !loaded { logger.error("a built-in extension did not load into a profile; its tabs open without it") }
        guard loads.answered(contextKey: load.context, generation: load.generation) else { return }
        for resume in waiters.removeValue(forKey: load.context) ?? [] { resume() }
    }
}
