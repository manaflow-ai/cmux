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
    private struct App: Equatable, Sendable {
        var id: String?
        var name: String?
    }

    private struct SessionState: Sendable {
        var label = ""
        var app: App?
        var sentAt: Date?
        var sentLabel = ""
        var sentApp: App?
    }

    private struct State: Sendable {
        var sessions: [String: SessionState] = [:]
        /// The window of the latest window capture, and when (a screenshot comes before the action).
        var capturedWindow: (id: UInt32, at: Date)?
        /// The app of each window resolved so far (a few entries; a window keeps its owner).
        var windowApps: [UInt32: App] = [:]
    }

    private let write: @Sendable (Data) -> Void
    private let clock: @Sendable () -> Date
    private let windowApp: @Sendable (UInt32) -> (id: String?, name: String?)?
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - write: Sends one control line to the host.
    ///   - clock: Now (a test passes its own).
    ///   - windowApp: The app that owns a window (CGWindowList); a test passes its own.
    init(write: @escaping @Sendable (Data) -> Void, clock: @escaping @Sendable () -> Date = { Date() },
         windowApp: @escaping @Sendable (UInt32) -> (id: String?, name: String?)? = ComputerUseActivityReporter.owner(ofWindow:)) {
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
            state.sessions[question.session, default: SessionState()].app = app
            if !question.agent.isEmpty { state.sessions[question.session]?.label = question.agent }
            return Self.due(&state, question.session, now: clock(), force: true)
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
        let window = given == nil ? state.withLockUnchecked { state -> UInt32? in
            guard let captured = state.capturedWindow, now.timeIntervalSince(captured.at) < 2 else { return nil }
            return state.windowApps[captured.id] == nil ? captured.id : nil
        } : nil
        // Outside the lock: one CGWindowList read for a window not seen before.
        let resolved = window.flatMap { id in windowApp(id).map { (id, App(id: $0.id, name: $0.name)) } }
        let line = state.withLockUnchecked { state -> Data? in
            if let (id, app) = resolved {
                if state.windowApps.count >= 64 { state.windowApps.removeAll() }
                state.windowApps[id] = app
            }
            var entry = state.sessions[session, default: SessionState()]
            if let label = object["label"] as? String, !label.isEmpty { entry.label = label }
            if let given {
                entry.app = given
            } else if let captured = state.capturedWindow, now.timeIntervalSince(captured.at) < 2,
                      let app = state.windowApps[captured.id] {
                entry.app = app
            }
            state.sessions[session] = entry
            return Self.due(&state, session, now: now, force: false)
        }
        if let line { write(line) }
    }

    /// The session's line when it is due: what it shows changed, or the interval passed.
    private static func due(_ state: inout State, _ session: String, now: Date, force: Bool) -> Data? {
        guard var entry = state.sessions[session] else { return nil }
        let changed = entry.label != entry.sentLabel || entry.app != entry.sentApp
        if !force, !changed, let sent = entry.sentAt, now.timeIntervalSince(sent) < ComputerUseActivity.minimumInterval { return nil }
        entry.sentAt = now
        entry.sentLabel = entry.label
        entry.sentApp = entry.app
        state.sessions[session] = entry
        return ComputerUseActivity.line(session: session, label: entry.label, appID: entry.app?.id, appName: entry.app?.name, at: now)
    }

    /// The bundle id and name of the app that owns window `id`; nil when it is gone.
    @Sendable static func owner(ofWindow id: UInt32) -> (id: String?, name: String?)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let info = list.first, let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return (app?.bundleIdentifier, app?.localizedName ?? info[kCGWindowOwnerName as String] as? String)
    }
}
