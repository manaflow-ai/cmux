// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation

/// What the Computer Use worker's agent sessions do now: which agent acts, on which app, and
/// when it acted last. The worker sends one `activity` line per session when it acts (at most
/// every ``ComputerUseActivity/minimumInterval`` unless what it shows changed) and one with
/// `ended` when the session's cursor goes away; the host keeps the latest per session and reports
/// them as `workers["computer-use"].activity`, which the cmux-tui daemon turns into its
/// `computer-use-activity` event for the app (the menu bar badge and Computer Use row).
///
///     worker -> host  {"type":"activity","session":S,"label":L,"app":{"id","name","pid"}?,"at_ms":T,"stopped":B?}
///     worker -> host  {"type":"activity","session":S,"ended":true}
public struct ComputerUseActivity: Equatable, Sendable {
    /// An app an agent acted on: its bundle id, name and process, each when known.
    public struct App: Equatable, Sendable {
        public var id: String?
        public var name: String?
        public var pid: Int32?

        public init(id: String? = nil, name: String? = nil, pid: Int32? = nil) {
            self.id = id
            self.name = name
            self.pid = pid
        }

        /// `{"id","name","pid"?}`.
        public var fields: [String: Any] {
            var fields: [String: Any] = ["id": id ?? "", "name": name ?? ""]
            if let pid { fields["pid"] = Int(pid) }
            return fields
        }

        init?(_ object: [String: Any]?) {
            guard let object else { return nil }
            let pid = (object["pid"] as? NSNumber)?.int32Value
            self.init(id: ComputerUseActivity.bounded(object["id"] as? String), name: ComputerUseActivity.bounded(object["name"] as? String),
                      pid: pid.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// One agent session that acted.
    public struct Session: Equatable, Sendable {
        /// The engine's session key.
        public var session: String
        /// The agent's name as the person sees it ("Claude Code").
        public var label: String
        /// The app it acted on last, when the worker knows it.
        public var app: App?
        /// When it acted last (milliseconds since 1970, this Mac's clock).
        public var lastActionMilliseconds: Int64
        /// The person stopped its Computer Use from the menu bar (its calls are refused until Resume).
        public var stopped: Bool

        public init(session: String, label: String, app: App? = nil, lastActionMilliseconds: Int64, stopped: Bool = false) {
            self.session = session
            self.label = label
            self.app = app
            self.lastActionMilliseconds = lastActionMilliseconds
            self.stopped = stopped
        }

        /// The status object (`{session, label, app?, last_action_ms, stopped?}`).
        public var fields: [String: Any] {
            var fields: [String: Any] = ["session": session, "label": label, "last_action_ms": lastActionMilliseconds]
            if let app { fields["app"] = app.fields }
            if stopped { fields["stopped"] = true }
            return fields
        }
    }

    /// The worker sends a session's line at most this often while nothing it shows changes.
    public static let minimumInterval: TimeInterval = 0.5
    /// A session that has not acted for this long is dropped (its agent went quiet without ending).
    public static let forgetAfter: TimeInterval = 15 * 60
    /// The most sessions kept; the oldest go first.
    public static let limit = 32

    /// The sessions by key.
    public private(set) var sessions: [String: Session] = [:]

    public init() {}

    /// The status list, newest action first.
    public var fields: [[String: Any]] {
        sessions.values.sorted { $0.lastActionMilliseconds > $1.lastActionMilliseconds }.map(\.fields)
    }

    /// Takes one `activity` line; returns whether anything the status shows changed.
    public mutating func take(_ line: [String: Any], now: Date) -> Bool {
        guard let session = line["session"] as? String, !session.isEmpty, session.count <= 256 else { return false }
        let horizon = Self.milliseconds(now.addingTimeInterval(-Self.forgetAfter))
        var changed = false
        for (key, value) in sessions where value.lastActionMilliseconds < horizon {
            sessions[key] = nil
            changed = true
        }
        if line["ended"] as? Bool == true {
            return sessions.removeValue(forKey: session) != nil || changed
        }
        let next = Session(session: session, label: Self.bounded(line["label"] as? String) ?? "", app: App(line["app"] as? [String: Any]),
                           lastActionMilliseconds: (line["at_ms"] as? NSNumber)?.int64Value ?? Self.milliseconds(now),
                           stopped: line["stopped"] as? Bool ?? false)
        guard sessions[session] != next else { return changed }
        sessions[session] = next
        if sessions.count > Self.limit,
           let oldest = sessions.values.min(by: { $0.lastActionMilliseconds < $1.lastActionMilliseconds }) {
            sessions[oldest.session] = nil
        }
        return true
    }

    /// The worker's line for an action of `session`.
    public static func line(session: String, label: String, app: App?, at: Date, stopped: Bool = false) -> Data {
        var fields: [String: Any] = ["type": "activity", "session": session, "label": label, "at_ms": milliseconds(at)]
        if let app { fields["app"] = app.fields }
        if stopped { fields["stopped"] = true }
        return RemoteWire.line(fields)
    }

    /// The worker's line for a session whose cursor went away.
    public static func endedLine(session: String) -> Data {
        RemoteWire.line(["type": "activity", "session": session, "ended": true])
    }

    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// One line of at most 80 characters, nil when empty: the label and app name reach the person.
    static func bounded(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80).map(Character.init))
        return line.isEmpty ? nil : line
    }
}
