// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteComputerUse
import CmuxRemoteWire
import Foundation
import os
import Testing

/// The worker's `activity` lines (which agent session acts, on which app) and the host's view of
/// them: what the app's menu bar badge and Computer Use row read through the daemon.
@Suite struct ComputerUseActivityTests {
    /// A clock the test moves, and the lines the reporter wrote.
    private final class Rig: Sendable {
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let lines = OSAllocatedUnfairLock(uncheckedState: [[String: Any]]())
        let windows: [UInt32: ComputerUseActivity.App]

        init(windows: [UInt32: ComputerUseActivity.App] = [:]) { self.windows = windows }

        func reporter() -> ComputerUseActivityReporter {
            ComputerUseActivityReporter(write: { data in
                if let object = RemoteWire.object(data.prefix { $0 != 0x0A }) { self.lines.withLockUnchecked { $0.append(object) } }
            }, clock: { self.now.withLock { $0 } }, windowApp: { self.windows[$0] })
        }

        func advance(_ seconds: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
        var written: [[String: Any]] { lines.withLockUnchecked { $0 } }
    }

    private func cursor(_ kind: String, session: String = "s1", label: String = "Claude Code", app: [String: Any]? = nil) -> Data {
        var event: [String: Any] = ["kind": kind, "session": session, "label": label, "at": ["x": 10, "y": 20]]
        if let app { event["app"] = app }
        if kind == "hide" { event = ["kind": "hide", "session": session] }
        return (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
    }

    @Test func anActionSaysWhoActsOnWhichAppAtMostEveryHalfSecond() {
        let rig = Rig(windows: [42: .init(id: "com.apple.TextEdit", name: "TextEdit", pid: 501)])
        let reporter = rig.reporter()
        reporter.noteCapture(CaptureRequest(target: .window(42), session: "s1"))
        reporter.noteCursor(cursor("look"))
        reporter.noteCursor(cursor("click"))
        rig.advance(0.2)
        reporter.noteCursor(cursor("move"))
        #expect(rig.written.count == 1, "the second and third actions fall in the same half second")
        let first = rig.written[0]
        #expect(first["type"] as? String == "activity" && first["session"] as? String == "s1")
        #expect(first["label"] as? String == "Claude Code")
        #expect((first["app"] as? [String: Any])?["name"] as? String == "TextEdit")
        #expect((first["app"] as? [String: Any])?["pid"] as? Int == 501)
        #expect((first["at_ms"] as? NSNumber)?.int64Value == 1_000_000)
        rig.advance(0.4)
        reporter.noteCursor(cursor("typing"))
        #expect(rig.written.count == 2, "a later action after the interval sends again")
        reporter.noteCursor(cursor("hide"))
        #expect(rig.written.last?["ended"] as? Bool == true)
        reporter.noteCursor(cursor("hide"))
        #expect(rig.written.count == 3, "a second hide of an ended session says nothing")
    }

    @Test func aNewAppOrAnAppTheEventNamesGoesAtOnce() {
        let rig = Rig(windows: [1: .init(id: "com.apple.Notes", name: "Notes"), 2: .init(id: "com.apple.Safari", name: "Safari")])
        let reporter = rig.reporter()
        reporter.noteCapture(CaptureRequest(target: .window(1), session: "s1"))
        reporter.noteCursor(cursor("look"))
        reporter.noteCapture(CaptureRequest(target: .window(2), session: "s1"))
        reporter.noteCursor(cursor("look"))
        #expect(rig.written.compactMap { ($0["app"] as? [String: Any])?["name"] as? String } == ["Notes", "Safari"])
        reporter.noteCursor(cursor("click", app: ["id": "com.example.Mail", "name": "Mail"]))
        #expect((rig.written.last?["app"] as? [String: Any])?["id"] as? String == "com.example.Mail")
        // A display capture names no app; an old window capture no longer does either.
        rig.advance(3)
        reporter.noteCapture(CaptureRequest(target: .display(nil), session: "s2"))
        reporter.noteCursor(cursor("click", session: "s2", label: "Codex"))
        #expect(rig.written.last?["app"] == nil && rig.written.last?["label"] as? String == "Codex")
    }

    /// Each session's window is the one it captured itself: agent B acting right after agent A's
    /// screenshot never takes A's window (the live preview would stream A's window in B's terminal),
    /// and a capture that names no session is nobody's.
    @Test func aSessionsWindowIsOnlyOneItCapturedItself() {
        let rig = Rig(windows: [7: .init(id: "com.apple.mail", name: "Mail", pid: 70), 8: .init(id: "com.apple.Notes", name: "Notes", pid: 80)])
        let reporter = rig.reporter()
        reporter.noteCapture(CaptureRequest(target: .window(7), session: "a"))
        reporter.noteCursor(cursor("click", session: "b", label: "Codex"))
        #expect(reporter.window(of: "b") == nil, "A's capture is not B's window")
        #expect(rig.written.last?["app"] == nil)
        reporter.noteCursor(cursor("click", session: "a"))
        #expect(reporter.window(of: "a") == ComputerUsePreview.SessionWindow(window: 7, app: .init(id: "com.apple.mail", name: "Mail", pid: 70)))
        reporter.noteCapture(CaptureRequest(target: .window(8)))
        rig.advance(1)
        reporter.noteCursor(cursor("click", session: "b", label: "Codex"))
        #expect(reporter.window(of: "b") == nil, "a capture with no session is nobody's")
        reporter.noteCapture(CaptureRequest(target: .window(8), session: "b"))
        reporter.noteCursor(cursor("click", session: "b", label: "Codex"))
        #expect(reporter.window(of: "b")?.window == 8)
        #expect(reporter.window(of: "a")?.window == 7, "B's capture leaves A's window alone")
    }

    @Test func captureRequestsReadTheirSession() {
        #expect(CaptureRequest(json: Data(#"{"window":"42","session":"terminal:t:9"}"#.utf8))
            == CaptureRequest(target: .window(42), session: "terminal:t:9"))
        #expect(CaptureRequest(json: Data(#"{"window":"42"}"#.utf8)) == CaptureRequest(target: .window(42)))
        #expect(CaptureRequest(json: Data(#"{"window":"42","session":""}"#.utf8))?.session == nil)
        #expect(CaptureRequest(json: Data(#"{"display":null,"exclude_pids":[3]}"#.utf8))?.target == .display(nil, excluding: [3]))
    }

    @Test func theHostKeepsTheLatestPerSessionAndForgetsEndedAndStaleOnes() {
        var activity = ComputerUseActivity()
        let now = Date(timeIntervalSince1970: 2_000)
        let first = activity.take(["type": "activity", "session": "a", "label": "Claude", "at_ms": 1_999_000,
                                   "app": ["id": "com.apple.Notes", "name": "Notes"]], now: now)
        #expect(first)
        let same = activity.take(["type": "activity", "session": "a", "label": "Claude", "at_ms": 1_999_000,
                                  "app": ["id": "com.apple.Notes", "name": "Notes"]], now: now)
        #expect(!same, "the same line changes nothing")
        let taken1 = activity.take(["type": "activity", "session": "b", "label": "Codex\u{7}\nbad", "at_ms": 2_000_000], now: now)
        #expect(taken1)
        let fields = activity.fields
        #expect(fields.map { $0["session"] as? String } == ["b", "a"], "newest first")
        #expect(fields[0]["label"] as? String == "Codexbad", "no control characters reach the person")
        #expect((fields[1]["app"] as? [String: Any])?["name"] as? String == "Notes")
        #expect((fields[1]["app"] as? [String: Any])?["pid"] == nil, "no pid when the line names none")
        let taken2 = activity.take(["type": "activity", "session": "a", "ended": true], now: now)
        #expect(taken2)
        #expect(activity.sessions.keys.sorted() == ["b"])
        let later = now.addingTimeInterval(ComputerUseActivity.forgetAfter + 1)
        let taken3 = activity.take(["type": "activity", "session": "c", "label": "Claude"], now: later)
        #expect(taken3)
        #expect(activity.sessions.keys.sorted() == ["c"], "a session quiet for 15 minutes is dropped")
        let taken4 = activity.take(["type": "activity", "label": "no session"], now: later)
        #expect(!taken4)
    }

    @Test func theCursorTagModeComesFromThePolicy() {
        #expect(PolicyFlags().cursorTag == .hover)
        let always = Data(#"{"cursorTag":"always","mode":"fullAccess"}"#.utf8)
        #expect(PolicyFlags(always).cursorTag == .always)
        #expect(PolicyFlags(Data(#"{"cursorTag":"sometimes"}"#.utf8)).cursorTag == .hover, "an unknown mode keeps the default")
    }
    @Test func aStoppedSessionSaysSoAtOnceAndItsRefusedCallsAreNoActions() {
        let rig = Rig(windows: [42: .init(id: "com.apple.TextEdit", name: "TextEdit", pid: 501)])
        let reporter = rig.reporter()
        reporter.noteCapture(CaptureRequest(target: .window(42), session: "s1"))
        reporter.noteCursor(cursor("click"))
        #expect(rig.written.count == 1)
        #expect(reporter.window(of: "s1")?.window == 42 && reporter.window(of: "s1")?.app?.pid == 501)
        rig.advance(1)
        reporter.noteStopped("s1", true)
        #expect(rig.written.count == 2, "the stop goes at once")
        #expect(rig.written[1]["stopped"] as? Bool == true)
        #expect((rig.written[1]["at_ms"] as? NSNumber)?.int64Value == 1_000_000, "the stop is not an action")
        // The engine's red Stopped event and the stopped agent's refused calls: no action, no line.
        rig.advance(1)
        reporter.noteCursor(cursor("refused"))
        rig.advance(1)
        reporter.noteCursor(cursor("refused"))
        #expect(rig.written.count == 2)
        reporter.noteStopped("s1", false)
        #expect(rig.written.count == 3 && rig.written[2]["stopped"] == nil, "resume clears it at once")
        rig.advance(1)
        reporter.noteCursor(cursor("click"))
        #expect((rig.written.last?["at_ms"] as? NSNumber)?.int64Value == 1_004_000, "a resumed session acts again")
    }

    @Test func theHostKeepsAStoppedSessionStopped() {
        var activity = ComputerUseActivity()
        let now = Date(timeIntervalSince1970: 1_000)
        let taken5 = activity.take(["session": "s1", "label": "Codex", "at_ms": 1_000_000], now: now)
        #expect(taken5)
        let taken6 = activity.take(["session": "s1", "label": "Codex", "at_ms": 1_000_000, "stopped": true], now: now)
        #expect(taken6)
        #expect(activity.fields.first?["stopped"] as? Bool == true)
        let taken7 = activity.take(["session": "s1", "label": "Codex", "at_ms": 1_000_000], now: now)
        #expect(taken7)
        #expect(activity.fields.first?["stopped"] == nil)
    }
}
