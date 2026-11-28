// SPDX-License-Identifier: GPL-3.0-or-later
public import CmuxNextActions
import CmuxNextCompat
import CmuxNextWakeups
public import CmuxNextComputerUse
public import CmuxNextDaemon
public import Foundation

/// One agent session of cmux Remote's Computer Use worker, as its `activity` reports it: who acts,
/// on which app, and when it acted last.
public struct CmuxRemoteComputerUseSession: Equatable, Sendable {
    /// The engine's session key.
    public var id: String
    /// The agent's name ("Claude Code"), nil when the worker has none.
    public var agent: String?
    /// The app it acted on last (its bundle id, name and process), nil when the worker does not know it.
    public var appID: String?
    public var appName: String?
    public var appPID: Int32?
    /// When it acted last.
    public var lastAction: Date
    /// The person stopped its Computer Use from the menu bar; its calls are refused until Resume.
    public var stopped: Bool

    public init(id: String, agent: String? = nil, appID: String? = nil, appName: String? = nil, appPID: Int32? = nil, lastAction: Date,
                stopped: Bool = false) {
        self.id = id
        self.agent = agent
        self.appID = appID
        self.appName = appName
        self.appPID = appPID
        self.lastAction = lastAction
        self.stopped = stopped
    }

    /// The session as the File menu's Computer Use actions and the drive indicator's Stop read it.
    /// The worker names no terminal: Focus Calling Terminal finds none.
    public var live: ComputerUseLiveSession {
        let target = appID == nil && appName == nil && appPID == nil
            ? nil : ComputerUseLiveSession.Target(pid: appPID, bundleID: appID, appName: appName)
        return ComputerUseLiveSession(id: id, lastActionAt: lastAction, target: target)
    }

    /// The session in Rust's shape (cmux-rd-ffi `remote::Session`).
    var rd: [String: Any] {
        var row: [String: Any] = ["id": id, "lastActionMs": lastAction.timeIntervalSince1970 * 1000, "stopped": stopped]
        row["agent"] = agent
        row["appId"] = appID
        row["appName"] = appName
        row["appPid"] = appPID.map { Int($0) }
        return row
    }

    /// A session Rust answered (`remote::Session`).
    init?(rd row: Any) {
        guard let row = row as? [String: Any], let id = row["id"] as? String, let millis = (row["lastActionMs"] as? NSNumber)?.doubleValue else { return nil }
        self.init(id: id, agent: row["agent"] as? String, appID: row["appId"] as? String, appName: row["appName"] as? String,
                  appPID: (row["appPid"] as? NSNumber)?.int32Value, lastAction: Date(timeIntervalSince1970: millis / 1000),
                  stopped: row["stopped"] as? Bool ?? false)
    }

    /// The sessions of a `computer-use-activity` event's `sessions`, or of the host status's
    /// `workers["computer-use"].activity`: `[{session, label, app: {id, name}?, last_action_ms, stopped?}]`,
    /// newest action first. Rows without a session are skipped (Rust: remote.activitySessions).
    public static func sessions(from list: [Any]?) -> [CmuxRemoteComputerUseSession] {
        rows(RdUI.call("remote.activitySessions", ["sessions": list ?? []]))
    }

    /// ``sessions(from:)`` from a daemon event's parsed `sessions`.
    public static func sessions(fromEvent list: [CmuxNextDaemon.JSONValue]) -> [CmuxRemoteComputerUseSession] {
        rows(RdUI.call("remote.activitySessions", encoding: ["sessions": list]))
    }

    private static func rows(_ answer: Any?) -> [CmuxRemoteComputerUseSession] {
        (answer as? [Any] ?? []).compactMap(CmuxRemoteComputerUseSession.init(rd:))
    }
}

/// Whether an agent is acting through Computer Use now: one acted within the menu bar badge's
/// window (Rust: remote.acting). The clear is one deadline (``DemandTimer``) at the newest
/// action's end of window, on an injected clock; nothing polls.
struct ComputerUseActingWindow: Sendable {
    /// Whether `sessions` hold an action within the window of `now`, and when that ends (nil: not acting).
    /// A stopped session never acts.
    static func acting(_ sessions: [CmuxRemoteComputerUseSession], now: Date) -> (acting: Bool, until: Date?) {
        let answer = RdUI.call("remote.acting", ["sessions": sessions.map(\.rd), "nowMs": now.timeIntervalSince1970 * 1000]) as? [String: Any]
        let until = (answer?["untilMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (answer?["acting"] as? Bool ?? false, until)
    }
}

extension CmuxRemoteComputerUseState {
    /// Takes the sessions the worker reports (`computer-use-activity`, or a status read) and sets
    /// ``acting``; while it is on, one wait ends it at the newest action's end of window.
    func take(activity sessions: [CmuxRemoteComputerUseSession]) {
        if self.sessions != sessions { self.sessions = sessions }
        settleActing()
    }

    /// The person stopped or resumed `session` and cmux Remote took it: the menu shows it at once
    /// (the worker's next `computer-use-activity` says the same).
    func mark(_ session: String, stopped: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == session }), sessions[index].stopped != stopped else { return }
        var next = sessions
        next[index].stopped = stopped
        take(activity: next)
    }

    /// Takes a daemon `computer-use-activity` event's payload.
    public func take(activityEvent payload: CmuxNextDaemon.JSONValue) {
        guard case .object = payload else { return }
        take(activity: CmuxRemoteComputerUseSession.sessions(fromEvent: payload["sessions"]?.arrayValue ?? []))
    }

    private func settleActing() {
        let (acting, until) = ComputerUseActingWindow.acting(sessions, now: now())
        if self.acting != acting { self.acting = acting }
        guard let until else { return actingClear.cancel() }
        let wait = max(until.timeIntervalSince(now()), 0)
        // One deadline at the end of the window; the next activity replaces it.
        actingClear.schedule(after: .milliseconds(Int64((wait * 1000).rounded(.up)))) { @MainActor [weak self] in
            self?.settleActing()
        }
    }

    /// The menu bar's Computer Use rows for the sessions now.
    public func menuBarSessions(now: Date = Date()) -> [MenuBarMenuState.ComputerUse.Session] {
        let rows = RdUI.call("remote.menuBar", ["sessions": sessions.map(\.rd), "nowMs": now.timeIntervalSince1970 * 1000]) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return MenuBarMenuState.ComputerUse.Session(id: id, agent: row["agent"] as? String, appName: row["appName"] as? String,
                                                        bundleID: row["bundleId"] as? String, acting: row["acting"] as? Bool ?? false,
                                                        stopped: row["stopped"] as? Bool ?? false)
        }
    }
}

extension CmuxRemoteService {
    /// Follows what the worker's agent sessions do: the daemon's `computer-use-activity` from
    /// `store` (pushed on a change, no polling) into ``computerUse``, and `changed` with
    /// ``CmuxRemoteComputerUseState/acting`` each time it or the sessions change (the menu bar's
    /// dot and its Computer Use row).
    public func followComputerUseActivity(_ store: DaemonStore, changed: @escaping @MainActor (_ acting: Bool) -> Void) {
        let state = computerUse
        _ = store.sideEvents.subscribe { [weak state] event in
            guard case .unknown(name: "computer-use-activity", let payload) = event else { return }
            state?.take(activityEvent: payload)
        }
        // task-owner: lives with the app; follows the activity state (Observation, no polling).
        Task { [weak state] in
            guard let state else { return }
            for await (acting, _) in ObservationStream({ (state.acting, state.sessions) }) { changed(acting) }
        }
    }
}
