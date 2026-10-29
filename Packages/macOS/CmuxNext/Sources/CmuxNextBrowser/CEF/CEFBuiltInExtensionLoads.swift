import CmuxNextWakeups
import Foundation
import os

/// The built-in extensions that load into each persistent profile before its first browser tab
/// (feature `chromiumAdBlockerAtFirstTab`): which profile loads, waits or may open its tabs.
/// Through `--load-extension` they loaded into every profile Chromium started, the root profile no cmux
/// tab uses too, so Home with no browser tab ran the built-in uBlock Origin's background page in a
/// renderer of its own. ``CEFBuiltInExtensionLoader`` runs the loads.
nonisolated struct CEFBuiltInExtensionLoads: Equatable, Sendable {
    /// What a tab of a profile does before its browser is asked for.
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
    /// This Chromium's loads by context key: how many folders have not answered yet (0: loaded).
    private var unanswered: [String: Int] = [:]
    /// Counts Chromium starts, so the answer of an earlier Chromium's load changes nothing.
    private(set) var generation = 0

    /// A Chromium start (also a Chromium Host's restart): `folders` load at first tabs, into no profile yet.
    mutating func started(folders: [String]) {
        self.folders = folders
        unanswered = [:]
        generation += 1
    }

    /// Before a tab of `key` (context `contextKey`) asks for its browser. An incognito or cmux page
    /// store (in memory: cmux runs no extension there, browser.md "Extensions in incognito") never waits.
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

    /// One folder's load into `contextKey` answered (loaded or not) in Chromium `generation`: true when
    /// it was the profile's last, so its waiting tabs ask for their browsers now.
    mutating func answered(contextKey: String, generation: Int) -> Bool {
        guard generation == self.generation, let left = unanswered[contextKey], left > 0 else { return false }
        unanswered[contextKey] = left - 1
        return left == 1
    }
}

/// Loads the built-in extensions into each persistent profile before its first browser tab and holds
/// that profile's tabs until the loads answered (one per runtime, ``CEFRuntime/builtInLoader``).
///
/// Chrome loads `--load-extension` folders synchronously at a profile's start "to avoid a race between
/// extension loading and loading an URL from the command line" (extensions/browser/unpacked_installer.cc,
/// `LoadFromCommandLine`). cmux keeps that order without the UI-thread read: the fork's
/// `cmux_ext_load_command_line_async` reads the folder on the extension file task runner and answers once
/// Chrome installed the extension and its background page finished its first load. The profile's first
/// tab asks for its browser only after that answer (``ready(for:in:resume:)``), so its first page loads
/// with the extension, also when it joins a window that is already live (the spare's): `tab_add`
/// navigates in the call. Every answer comes in a synchronous turn (the shim's CMUX_SHIM_REPLY, the
/// host's REPLY, a deadline on ``CEFRuntime/waitDeadlines``): no task of its own waits.
final class CEFBuiltInExtensionLoader {
    /// How long a load may take before the profile's tabs open without it: past it the fork may still
    /// finish the load, as a mojo message still runs after its caller stopped waiting.
    static let timeout: Duration = .seconds(10)
    /// The `WakeupLedger` owner of the loads' deadlines.
    static let deadlineOwner = "CEFBuiltInExtensionLoader.load"

    /// One folder's load waiting for the fork's answer, by its reply id.
    private struct Pending {
        let context: String
        let generation: Int
        let deadlines: AlignedWakeups
        let deadline: AlignedWakeups.Ticket
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")
    /// The feature `chromiumAdBlockerAtFirstTab` (the App sets it before Chromium starts).
    var featureOn = false
    private(set) var loads = CEFBuiltInExtensionLoads()
    /// The tabs waiting for their profile's load, by context key.
    private var waiters: [String: [() -> Void]] = [:]
    private var pending: [Int32: Pending] = [:]

    /// A Chromium start (also a Chromium Host's restart): true when `folders` stay off `--load-extension`
    /// and load at first tabs (the feature on, a fork with the call, a folder to load). A tab that waited
    /// for the previous Chromium's load asks again, against this one.
    func start(_ folders: [String], forkSupports: Bool) -> Bool {
        let atFirstTab = featureOn && forkSupports && !folders.isEmpty
        loads.started(folders: atFirstTab ? folders : [])
        for load in pending.values { _ = load.deadlines.cancel(load.deadline) }
        pending.removeAll()
        let waiting = waiters.values.flatMap { $0 }
        waiters.removeAll()
        for resume in waiting { resume() }
        return atFirstTab
    }

    /// Whether `tab`'s browser may be asked for now. The first tab of a persistent profile starts the
    /// load of the built-in extensions; it and every tab of the profile that asks meanwhile wait, and
    /// `resume` runs once, when the load's last answer (or its deadline) comes: in this turn only when
    /// the shim refuses the load at once in process. A spare's placeholder never waits and loads
    /// nothing: Home keeps no extension renderer.
    func ready(for tab: CEFTab, in host: CEFPaneHost, resume: @escaping () -> Void) -> Bool {
        guard host.placeholder !== tab else { return true }
        let context = host.runtime.contextKey(for: host.key)
        let gate = loads.gate(host.key, contextKey: context)
        guard gate != .open else { return true }
        waiters[context, default: []].append(resume)
        if case .start(let folders) = gate { load(folders, into: context, runtime: host.runtime) }
        return false
    }

    /// A CMUX_SHIM_REPLY: true when it answers one of the loads (1: the extension is in), which then
    /// takes no site reply waiter.
    func answer(reply id: Int32, value: Int64) -> Bool {
        guard pending[id] != nil else { return false }
        finish(id, loaded: value == 1)
        return true
    }

    /// Starts one load per folder, each answered by a CMUX_SHIM_REPLY under its own reply id (from the
    /// site replies' ids, so the two never meet). A start the shim refuses (at once in process, in the
    /// host's REPLY in host mode) ends its load then; the last load's end wakes the waiting tabs.
    private func load(_ folders: [String], into context: String, runtime: CEFRuntime) {
        let generation = loads.generation
        for folder in folders {
            let id = runtime.nextSiteReply
            runtime.nextSiteReply = id == .max ? 1 : id + 1
            let deadlines = runtime.waitDeadlines
            let deadline = deadlines.schedule(owner: Self.deadlineOwner, after: Self.timeout) { [weak self] in
                self?.finish(id, loaded: false)
            }
            pending[id] = Pending(context: context, generation: generation, deadlines: deadlines, deadline: deadline)
            let sent = runtime.sendAsync { shim in shim.extLoadCommandLine(context, id, folder) }
            runtime.whenAnswered(sent, label: "built-in extension load") { [weak self] started in
                if started != 1 { self?.finish(id, loaded: false) }
            }
        }
    }

    /// Ends load `id` once (its answer, its refused start or its deadline); the profile's last load
    /// wakes its waiting tabs.
    private func finish(_ id: Int32, loaded: Bool) {
        guard let load = pending.removeValue(forKey: id) else { return }
        _ = load.deadlines.cancel(load.deadline)
        if !loaded { logger.error("a built-in extension did not load into a profile; its tabs open without it") }
        guard loads.answered(contextKey: load.context, generation: load.generation) else { return }
        for resume in waiters.removeValue(forKey: load.context) ?? [] { resume() }
    }
}

extension CEFEngine {
    /// The default-off feature `chromiumAdBlockerAtFirstTab` (``CEFBuiltInExtensionLoader``): the built-in
    /// ad blocker loads at each profile's first browser tab, not at Chromium's start. Set before Chromium
    /// starts; read once, at the start.
    public func setAdBlockerAtFirstTab(_ on: Bool) {
        CEFRuntime.shared.builtInLoader.featureOn = on
    }
}
