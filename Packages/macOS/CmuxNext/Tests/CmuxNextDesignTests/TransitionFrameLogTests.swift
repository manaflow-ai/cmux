import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The always-on transition frame log (instant-splits): a drag's input is its first move's event, one line per drag.
@MainActor struct TransitionFrameLogTests {
    static func log() -> TransitionFrameLog {
        TransitionFrameLog(directory: FileManager.default.temporaryDirectory.appending(path: "frame-timing-\(UUID().uuidString)"), build: "1")
    }

    static func drag(at timestamp: TimeInterval) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    @Test func theFirstMoveIsTheInputAndLaterMovesKeepIt() {
        let log = Self.log()
        log.input(now: 100, event: Self.drag(at: 99.99)) // not armed: no timing
        #expect(log.pendingInput == nil)
        log.arm(.dividerDrag)
        log.input(now: 100, event: Self.drag(at: 99.99))
        log.input(now: 100.5, event: Self.drag(at: 100.49))
        #expect(log.pendingInput?.time == 99.99)
        #expect(log.pendingInput?.fromEvent == true)
    }

    @Test func aStaleOrMissingEventFallsBackToNow() {
        let log = Self.log()
        log.arm(.dividerDrag)
        log.input(now: 100, event: Self.drag(at: 90))
        #expect(log.pendingInput?.time == 100)
        #expect(log.pendingInput?.fromEvent == false)
    }

    @Test func aCancelOrAWindowlessChangeWritesNothing() {
        let log = Self.log()
        var lines: [String] = []
        log.onLine = { lines.append($0) }
        log.arm(.dividerDrag)
        log.input(now: 100, event: nil)
        log.cancel()
        #expect(log.pendingInput == nil)
        log.arm(.dividerDrag)
        log.input(now: 100, event: nil)
        log.changed(in: nil)
        #expect(log.pendingInput == nil)
        #expect(lines.isEmpty)
    }

    @Test func aLineIsOneJSONObjectWithTheReaderFields() throws {
        let line = TransitionFrameLog.line(.dividerDrag, input: 81_234.5, displayed: 81_234.5109, ended: 81_234.5121, fromEvent: true,
                                           build: "4584735850101", atMilliseconds: 1_795_000_000_000)
        #expect(line.hasSuffix("\n"))
        #expect(line.dropLast().contains("\n") == false)
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["transition"] as? String == "divider_drag")
        #expect(abs((object["ms"] as? Double ?? 0) - 12.1) < 0.02)
        #expect(abs((object["commit_ms"] as? Double ?? 0) - 10.9) < 0.02)
        #expect(object["event"] as? Bool == true)
        #expect(object["build"] as? String == "4584735850101")
    }

    @Test func aSplitKeyPressIsTheInputAndALateChangeTimesNothing() {
        let log = Self.log()
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 99.995, windowNumber: 0,
                                   context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)
        log.arm(.rightSplitOpen)
        #expect(log.pendingTransition == .rightSplitOpen)
        log.input(now: 100, event: key)
        #expect(log.pendingInput?.time == 99.995)
        #expect(log.pendingInput?.fromEvent == true)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.wantsLayer = true
        log.changed(in: window, now: 100 + TransitionFrameLog.maximumChangeWait)
        #expect(log.pendingInput == nil)
        #expect(log.pendingTransition == nil)
    }

    @Test func aLineCarriesItsPath() throws {
        let line = TransitionFrameLog.line(.rightSplitOpen, input: 10, displayed: 10.004, ended: 10.004, fromEvent: true, build: "1",
                                           atMilliseconds: 1, path: "snapshot")
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["transition"] as? String == "right_split_open")
        #expect(object["path"] as? String == "snapshot")
        #expect(abs((object["ms"] as? Double ?? 0) - 4) < 0.02)
        let bare = TransitionFrameLog.line(.dividerDrag, input: 10, displayed: 10.004, ended: 10.005, fromEvent: true, build: "1", atMilliseconds: 1)
        #expect(!bare.contains("path"))
    }

    /// A drag's work line (instant-splits gap row 1): what its counters moved from its press to its release, and its moves.
    @Test func aReleaseWritesWhatTheCountersMovedInTheDrag() throws {
        let log = Self.log()
        var lines: [String] = []
        log.onLine = { lines.append($0) }
        var joined = 40, detaches = 2
        log.workCounts = { [("fence_joined", joined), ("detaches", detaches)] }
        log.arm(.dividerDrag)
        joined += 1 // before the first move: still this drag's
        log.input(now: 100, event: nil)
        log.input(now: 100.1, event: nil)
        log.input(now: 100.2, event: nil)
        joined += 30
        log.ended(now: 100.25)
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["transition"] as? String == "divider_drag_work")
        #expect(abs((object["ms"] as? Double ?? 0) - 250) < 0.02)
        #expect(object["moves"] as? Int == 3)
        #expect(object["fence_joined"] as? Int == 31)
        #expect(object["detaches"] as? Int == 0)
        log.ended(now: 101) // once a drag
        #expect(lines.count == 1)
    }

    @Test func aCancelledOrUncountedDragWritesNoWorkLine() {
        let log = Self.log()
        var lines: [String] = []
        log.onLine = { lines.append($0) }
        log.arm(.dividerDrag)
        log.input(now: 100, event: nil)
        log.ended(now: 100.2) // no counters: no line
        log.workCounts = { [("fences", 1)] }
        log.arm(.dividerDrag)
        log.input(now: 100, event: nil)
        log.cancel()
        log.ended(now: 100.2)
        log.arm(.dividerDrag)
        log.ended(now: 100.2) // released with no move
        #expect(lines.isEmpty)
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.wantsLayer = true
        return window
    }

    /// The frame-timeline fields (instant-splits): the first frame's commit, the last move's commit as the settle, and
    /// what the first frame showed, in one line at the settle.
    @Test func aTransitionWritesItsSettleSurfaceBlankAndDriftAtTheSettle() throws {
        let log = Self.log(), window = Self.window()
        var lines: [String] = []
        log.onLine = { lines.append($0) }
        log.arm(.splitOpen)
        log.input(now: 100, event: nil)
        log.changed(in: window, surface: "terminal", blank: true, drift: { 0.5 }, now: 100.001)
        log.committed(displayed: 100.010, ended: 100.012)
        #expect(log.isSettling)
        #expect(lines.isEmpty) // waits for its settle
        log.moved(in: window)
        log.committed(displayed: 100.150, ended: 100.152)
        log.settle()
        #expect(!log.isSettling)
        let object = try #require(JSONSerialization.jsonObject(with: Data(try #require(lines.first).utf8)) as? [String: Any])
        #expect(lines.count == 1)
        #expect(object["transition"] as? String == "split_open")
        #expect(abs((object["ms"] as? Double ?? 0) - 12) < 0.02)
        #expect(abs((object["settled_ms"] as? Double ?? 0) - 152) < 0.02)
        #expect(abs((object["settled_ts"] as? Double ?? 0) - 100.152) < 0.0001)
        #expect(object["surface"] as? String == "terminal")
        #expect(object["blank_first_frame"] as? Bool == true)
        #expect(object["drift_px"] as? Double == 0.5)
    }

    @Test func aChangeForAnotherKindIsNotThisTransitionsAndTheNextArmSettlesTheLast() throws {
        let log = Self.log(), window = Self.window()
        var lines: [String] = []
        log.onLine = { lines.append($0) }
        log.arm(.sideOpen)
        log.input(now: 100, event: nil)
        log.changed(in: window, for: [.dividerDrag], now: 100.001) // a drag's change: not the sidebar's
        #expect(log.pendingTransition == .sideOpen)
        log.changed(in: window, for: [.sideOpen, .sideClose], now: 100.002)
        log.committed(displayed: 100.008, ended: 100.009)
        log.cancel() // past its first frame: kept to its settle
        #expect(log.isSettling)
        log.arm(.paneClose)
        let object = try #require(JSONSerialization.jsonObject(with: Data(try #require(lines.first).utf8)) as? [String: Any])
        #expect(object["transition"] as? String == "side_open")
        #expect(object["settled_ts"] as? Double == object["first_frame_ts"] as? Double) // nothing moved after it
        #expect(object["blank_first_frame"] == nil) // no signal: no field
        #expect(log.pendingTransition == .paneClose)
    }

    @Test func aLineWithNoSettleSettlesAtItsFirstFrame() throws {
        let line = TransitionFrameLog.line(.zoom, input: 10, displayed: 10.004, ended: 10.005, fromEvent: false, build: "1",
                                           atMilliseconds: 1, settled: 10.001, surface: "Bad\"Kind", drift: .nan)
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["transition"] as? String == "zoom")
        #expect(object["settled_ts"] as? Double == 10.005)
        #expect(object["surface"] == nil) // not a plain word: not written
        #expect(object["drift_px"] == nil)
    }
}
