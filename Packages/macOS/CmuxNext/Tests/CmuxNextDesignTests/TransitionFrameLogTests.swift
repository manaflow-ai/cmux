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
}
