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
        let lines = OSAllocatedUnfairLock(initialState: [[String: Any]]())
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
        reporter.noteCapture(.window(42))
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
        reporter.noteCapture(.window(1))
        reporter.noteCursor(cursor("look"))
        reporter.noteCapture(.window(2))
        reporter.noteCursor(cursor("look"))
        #expect(rig.written.compactMap { ($0["app"] as? [String: Any])?["name"] as? String } == ["Notes", "Safari"])
        reporter.noteCursor(cursor("click", app: ["id": "com.example.Mail", "name": "Mail"]))
        #expect((rig.written.last?["app"] as? [String: Any])?["id"] as? String == "com.example.Mail")
        // A display capture names no app; an old window capture no longer does either.
        rig.advance(3)
        reporter.noteCapture(.display(nil))
        reporter.noteCursor(cursor("click", session: "s2", label: "Codex"))
        #expect(rig.written.last?["app"] == nil && rig.written.last?["label"] as? String == "Codex")
    }

    @Test func theHostKeepsTheLatestPerSessionAndForgetsEndedAndStaleOnes() {
        var activity = ComputerUseActivity()
        let now = Date(timeIntervalSince1970: 2_000)
        #expect(activity.take(["type": "activity", "session": "a", "label": "Claude", "at_ms": 1_999_000,
                               "app": ["id": "com.apple.Notes", "name": "Notes"]], now: now))
        #expect(!activity.take(["type": "activity", "session": "a", "label": "Claude", "at_ms": 1_999_000,
                                "app": ["id": "com.apple.Notes", "name": "Notes"]], now: now), "the same line changes nothing")
        #expect(activity.take(["type": "activity", "session": "b", "label": "Codex\u{7}\nbad", "at_ms": 2_000_000], now: now))
        let fields = activity.fields
        #expect(fields.map { $0["session"] as? String } == ["b", "a"], "newest first")
        #expect(fields[0]["label"] as? String == "Codexbad", "no control characters reach the person")
        #expect((fields[1]["app"] as? [String: Any])?["name"] as? String == "Notes")
        #expect((fields[1]["app"] as? [String: Any])?["pid"] == nil, "no pid when the line names none")
        #expect(activity.take(["type": "activity", "session": "a", "ended": true], now: now))
        #expect(activity.sessions.keys.sorted() == ["b"])
        let later = now.addingTimeInterval(ComputerUseActivity.forgetAfter + 1)
        #expect(activity.take(["type": "activity", "session": "c", "label": "Claude"], now: later))
        #expect(activity.sessions.keys.sorted() == ["c"], "a session quiet for 15 minutes is dropped")
        #expect(!activity.take(["type": "activity", "label": "no session"], now: later))
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
        reporter.noteCapture(.window(42))
        reporter.noteCursor(cursor("click"))
        #expect(rig.written.count == 1)
        #expect(reporter.window(of: "s1")?.window == 42 && reporter.window(of: "s1")?.pid == 501)
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
        #expect(activity.take(["session": "s1", "label": "Codex", "at_ms": 1_000_000], now: now))
        #expect(activity.take(["session": "s1", "label": "Codex", "at_ms": 1_000_000, "stopped": true], now: now))
        #expect(activity.fields.first?["stopped"] as? Bool == true)
        #expect(activity.take(["session": "s1", "label": "Codex", "at_ms": 1_000_000], now: now))
        #expect(activity.fields.first?["stopped"] == nil)
    }
}
