// SPDX-License-Identifier: GPL-3.0-or-later
public import CmuxNextDaemon
public import Foundation

/// One agent session of cmux Remote's Computer Use worker, as its `activity` reports it: who acts,
/// on which app, and when it acted last.
public struct CmuxRemoteComputerUseSession: Equatable, Sendable {
    /// The engine's session key.
    public var id: String
    /// The agent's name ("Claude Code"), nil when the worker has none.
    public var agent: String?
    /// The app it acted on last (its bundle id and name), nil when the worker does not know it.
    public var appID: String?
    public var appName: String?
    /// When it acted last.
    public var lastAction: Date

    public init(id: String, agent: String? = nil, appID: String? = nil, appName: String? = nil, lastAction: Date) {
        self.id = id
        self.agent = agent
        self.appID = appID
        self.appName = appName
        self.lastAction = lastAction
    }

    /// The sessions of a `computer-use-activity` event's `sessions`, or of the host status's
    /// `workers["computer-use"].activity`: `[{session, label, app: {id, name}?, last_action_ms}]`,
    /// newest action first. Rows without a session are skipped.
    public static func sessions(from list: [Any]?) -> [CmuxRemoteComputerUseSession] {
        (list ?? []).compactMap { row -> CmuxRemoteComputerUseSession? in
            guard let row = row as? [String: Any], let id = row["session"] as? String, !id.isEmpty,
                  let millis = (row["last_action_ms"] as? NSNumber)?.doubleValue else { return nil }
            let app = row["app"] as? [String: Any]
            return CmuxRemoteComputerUseSession(id: id, agent: nonEmpty(row["label"]), appID: nonEmpty(app?["id"]),
                                                appName: nonEmpty(app?["name"]), lastAction: Date(timeIntervalSince1970: millis / 1000))
        }.sorted { $0.lastAction > $1.lastAction }
    }
}

/// Whether an agent is acting through Computer Use now: one acted within ``window`` (the menu bar
/// badge). The clear is one bounded wait for the newest action's end of window, on an injected
/// clock; nothing polls.
struct ComputerUseActingWindow: Sendable {
    /// How long after its last action an agent still counts as acting.
    static let window: TimeInterval = 2

    /// Whether `sessions` hold an action within the window of `now`, and when that ends (nil: not acting).
    static func acting(_ sessions: [CmuxRemoteComputerUseSession], now: Date) -> (acting: Bool, until: Date?) {
        guard let newest = sessions.map(\.lastAction).max() else { return (false, nil) }
        let until = newest.addingTimeInterval(window)
        return until > now ? (true, until) : (false, nil)
    }
}

extension CmuxRemoteComputerUseState {
    /// Takes the sessions the worker reports (`computer-use-activity`, or a status read) and sets
    /// ``acting``; while it is on, one wait ends it at the newest action's end of window.
    func take(activity sessions: [CmuxRemoteComputerUseSession]) {
        if self.sessions != sessions { self.sessions = sessions }
        settleActing()
    }

    /// Takes a daemon `computer-use-activity` event's payload.
    public func take(activityEvent payload: CmuxNextDaemon.JSONValue) {
        guard let data = try? JSONEncoder().encode(payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        take(activity: CmuxRemoteComputerUseSession.sessions(from: object["sessions"] as? [Any]))
    }

    private func settleActing() {
        let (acting, until) = ComputerUseActingWindow.acting(sessions, now: now())
        if self.acting != acting { self.acting = acting }
        actingClear?.cancel()
        actingClear = nil
        guard let until else { return }
        let wait = until.timeIntervalSince(now())
        // task-owner: the one pending clear of the badge; replaced by the next activity.
        actingClear = Task { [weak self, sleep] in
            // An intentional bounded delay (the badge's 2 s window), on the injected clock.
            try? await sleep(.milliseconds(Int64((max(wait, 0) * 1000).rounded(.up))))
            guard !Task.isCancelled, let self else { return }
            self.actingClear = nil
            self.settleActing()
        }
    }
}

nonisolated private func nonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return text
}
