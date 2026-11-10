// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxRemoteWire
import CoreGraphics
import Foundation
import os

/// Tells the host which agent sessions act, from the engine's callbacks (any engine thread, never
/// blocking): each cursor event is an action of its session, the window an agent captured last
/// names the app it works in, and an approval question names its app outright. One `activity` line
/// (``ComputerUseActivity``) per session at most every half second unless its label or app changed,
/// and one when its cursor hides (the session ended or its grant was revoked).
final class ComputerUseActivityReporter: Sendable {
    private typealias App = ComputerUseActivity.App

    private struct SessionState: Sendable {
        var label = ""
        var app: App?
        /// The window it worked in last (the capture before its action), for Show Window.
        var window: UInt32?
        /// When it acted last; a stopped session's refused calls do not count.
        var actedAt: Date?
        var stopped = false
        var sentAt: Date?
        var sentLabel = ""
        var sentApp: App?
        var sentStopped = false
    }

    private struct State: Sendable {
        var sessions: [String: SessionState] = [:]
        /// The window of the latest window capture, and when (a screenshot comes before the action).
        var capturedWindow: (id: UInt32, at: Date)?
        /// The app of each window resolved so far (a few entries; a window keeps its owner).
        var windowApps: [UInt32: App] = [:]
        /// The sessions the person stopped (kept when a session's cursor hides, so it shows again stopped).
        var stopped: Set<String> = []
    }

    private let write: @Sendable (Data) -> Void
    private let clock: @Sendable () -> Date
    private let windowApp: @Sendable (UInt32) -> ComputerUseActivity.App?
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - write: Sends one control line to the host.
    ///   - clock: Now (a test passes its own).
    ///   - windowApp: The app that owns a window (CGWindowList); a test passes its own.
    init(write: @escaping @Sendable (Data) -> Void, clock: @escaping @Sendable () -> Date = { Date() },
         windowApp: @escaping @Sendable (UInt32) -> ComputerUseActivity.App? = { ComputerUseActivityReporter.owner(ofWindow: $0) }) {
        self.write = write
        self.clock = clock
        self.windowApp = windowApp
    }

    /// The engine captured `target` (`capture`'s JSON).
    func noteCapture(_ target: CaptureTarget) {
        guard case .window(let id) = target else { return }
        let now = clock()
        state.withLock { $0.capturedWindow = (id, now) }
    }

    /// The engine asked the person about `question`'s app for its session.
    func noteQuestion(_ question: ApprovalQuestion) {
        guard !question.session.isEmpty else { return }
        let app = App(id: question.appID.isEmpty ? nil : question.appID, name: question.appName)
        let line = state.withLockUnchecked { state -> Data? in
            var entry = state.sessions[question.session] ?? SessionState(stopped: state.stopped.contains(question.session))
            entry.app = app
            if !question.agent.isEmpty { entry.label = question.agent }
            let now = clock()
            if !entry.stopped { entry.actedAt = now }
            state.sessions[question.session] = entry
            return Self.due(&state, question.session, now: now, force: true)
        }
        if let line { write(line) }
    }

    /// One `cursor` callback (cursor.rs `CursorEvent` JSON): any kind but `hide` is an action of
    /// its session; `hide` ends it. An `app` object on the event (`{"id","name"}`) wins over the
    /// captured window.
    func noteCursor(_ json: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let kind = object["kind"] as? String, let session = object["session"] as? String, !session.isEmpty else { return }
        if kind == "hide" {
            let ended = state.withLockUnchecked { $0.sessions.removeValue(forKey: session) != nil }
            if ended { write(ComputerUseActivity.endedLine(session: session)) }
            return
        }
        let now = clock()
        let given = (object["app"] as? [String: Any]).map { App(id: $0["id"] as? String, name: $0["name"] as? String) }
        // The window captured within the last 2 s names the app, unless the event names one.
        var window: UInt32?
        if given == nil {
            window = state.withLockUnchecked { state -> UInt32? in
                guard let captured = state.capturedWindow, now.timeIntervalSince(captured.at) < 2 else { return nil }
                return state.windowApps[captured.id] == nil ? captured.id : nil
            }
        }
        // Outside the lock: one CGWindowList read for a window not seen before.
        let resolved = window.flatMap { id in windowApp(id).map { (id, $0) } }
        let line = state.withLockUnchecked { state -> Data? in
            if let (id, app) = resolved {
                if state.windowApps.count >= 64 { state.windowApps.removeAll() }
                state.windowApps[id] = app
            }
            var entry = state.sessions[session] ?? SessionState(stopped: state.stopped.contains(session))
            if let label = object["label"] as? String, !label.isEmpty { entry.label = label }
            // A stopped session's calls are refused: they are not actions (no badge, no newer row).
            if entry.stopped {
                state.sessions[session] = entry
                return nil
            }
            entry.actedAt = now
            if let given {
                entry.app = given
            } else if let captured = state.capturedWindow, now.timeIntervalSince(captured.at) < 2,
                      let app = state.windowApps[captured.id] {
                entry.app = app
            }
            if let captured = state.capturedWindow, now.timeIntervalSince(captured.at) < 2 { entry.window = captured.id }
            state.sessions[session] = entry
            return Self.due(&state, session, now: now, force: false)
        }
        if let line { write(line) }
    }

    /// The person stopped (`true`) or resumed `session`; its line says so at once. Call it before
    /// the engine stops the session (the engine's red Stopped cursor event is then no action) and
    /// after it resumes it.
    func noteStopped(_ session: String, _ stopped: Bool) {
        let line = state.withLockUnchecked { state -> Data? in
            if stopped { state.stopped.insert(session) } else { state.stopped.remove(session) }
            guard var entry = state.sessions[session] else { return nil }
            entry.stopped = stopped
            state.sessions[session] = entry
            return Self.due(&state, session, now: clock(), force: true)
        }
        if let line { write(line) }
    }

    /// The window `session` worked in last and its app's process (Show Window), nil when unknown.
    func window(of session: String) -> (window: UInt32, pid: Int32?)? {
        state.withLockUnchecked { state in
            guard let entry = state.sessions[session], let window = entry.window else { return nil }
            return (window, entry.app?.pid)
        }
    }

    /// The session's line when it is due: what it shows changed, or the interval passed.
    private static func due(_ state: inout State, _ session: String, now: Date, force: Bool) -> Data? {
        guard var entry = state.sessions[session] else { return nil }
        let changed = entry.label != entry.sentLabel || entry.app != entry.sentApp || entry.stopped != entry.sentStopped
        if !force, !changed, let sent = entry.sentAt, now.timeIntervalSince(sent) < ComputerUseActivity.minimumInterval { return nil }
        entry.sentAt = now
        entry.sentLabel = entry.label
        entry.sentApp = entry.app
        entry.sentStopped = entry.stopped
        state.sessions[session] = entry
        return ComputerUseActivity.line(session: session, label: entry.label, app: entry.app, at: entry.actedAt ?? now,
                                        stopped: entry.stopped)
    }

    /// The app that owns window `id` (its bundle id, name and process); nil when it is gone.
    static func owner(ofWindow id: UInt32) -> ComputerUseActivity.App? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let info = list.first, let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return App(id: app?.bundleIdentifier, name: app?.localizedName ?? info[kCGWindowOwnerName as String] as? String, pid: pid)
    }
}
