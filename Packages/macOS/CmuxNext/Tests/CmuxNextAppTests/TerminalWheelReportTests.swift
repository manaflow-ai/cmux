import AppKit
import CmuxNextTestSupport
import CoreGraphics
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// #22265: a mouse wheel over Codex typed `[<65;20;10M` into its composer. Codex (crossterm) shows
/// such text only when a report reaches it without its ESC, so every byte a wheel event makes must
/// arrive as whole reports. Drives a real Ghostty mirror surface (`GHOSTTY_SURFACE_IO_MANUAL_MIRROR`,
/// the daemon's mode) with the modes Codex 0.163 sets, then real `NSEvent` scrolls: wheel notches,
/// trackpad gestures with momentum, sideways swipes, and the same after a replay swaps the surface.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalWheelReportTests {
    /// What Codex 0.163 prints on start (captured from its PTY): alt screen, button and any-motion
    /// mouse tracking in SGR, focus reports, no alternate scroll, bracketed paste, kitty keys.
    static let codexModes = "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[?1007l\u{1b}[?2004h\u{1b}[>5u"

    final class Harness {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        @MainActor init() throws {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            window.isReleasedWhenClosed = false
            window.contentView = session.view
            session.view.layoutSubtreeIfNeeded()
        }

        @MainActor func close() {
            io.finish()
            window.close()
        }

        /// The point in the window's middle, where the pointer sits.
        @MainActor var middle: NSPoint { NSPoint(x: 240, y: 120) }

        /// Feeds `text` as program output and waits until the surface has it (the mouse mode on).
        @MainActor func output(_ text: String, until done: @MainActor () -> Bool) async throws {
            io.send(.output(Data(text.utf8)))
            try await wait(done)
        }

        @MainActor func wait(_ done: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline, !done() {
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        @MainActor var reporting: Bool {
            guard let surface = session.surfaceView.surface else { return false }
            return ghostty_surface_mouse_captured(surface)
        }

        @MainActor func move(to point: NSPoint) {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 0, pressure: 0)!
            session.surfaceView.mouseMoved(with: event)
        }

        /// One scroll as AppKit delivers it.
        @MainActor func scroll(dx: Int32 = 0, dy: Int32, units: CGScrollEventUnit, phase: CGScrollPhase? = nil,
                               momentum: CGMomentumScrollPhase = .none) {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
            if units == .pixel { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            cg.location = window.convertPoint(toScreen: middle)
            session.surfaceView.scrollWheel(with: NSEvent(cgEvent: cg)!)
        }

        /// Every input write since `start`, waiting briefly for Ghostty's IO thread.
        @MainActor func writes(since start: Int) async throws -> [Data] {
            var last = -1
            for _ in 0..<25 {
                try await Task.sleep(for: .milliseconds(40))
                let count = io.writes.count
                if count == last { break }
                last = count
            }
            return Array(io.writes.dropFirst(start))
        }
    }

    /// A whole SGR mouse report or focus report, nothing else.
    static let report = try! Regex(#"^(\x1b\[<\d+;\d+;\d+[Mm]|\x1b\[[IO])+$"#)

    static func check(_ writes: [Data], _ label: String) {
        for write in writes {
            let text = String(decoding: write, as: UTF8.self)
            #expect(text.wholeMatch(of: report) != nil, "\(label): a write is not whole reports: \(text.debugDescription)")
        }
    }

    @Test func wheelNotchesAndTrackpadGesturesWriteWholeReports() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.output(Self.codexModes) { h.reporting }
        #expect(h.reporting, "the mirror never turned mouse reporting on")
        h.move(to: h.middle)

        var start = h.io.writes.count
        for _ in 0..<3 { h.scroll(dy: -1, units: .line) }
        let notches = try await h.writes(since: start)
        Self.check(notches, "wheel notches")
        #expect(!notches.isEmpty, "wheel notches wrote no report")

        start = h.io.writes.count
        h.scroll(dy: 0, units: .pixel, phase: .mayBegin)
        h.scroll(dy: -6, units: .pixel, phase: .began)
        for _ in 0..<12 { h.scroll(dy: -23, units: .pixel, phase: .changed) }
        h.scroll(dy: 0, units: .pixel, phase: .ended)
        for _ in 0..<10 { h.scroll(dy: -15, units: .pixel, momentum: .continuous) }
        h.scroll(dy: 0, units: .pixel, momentum: .end)
        let gesture = try await h.writes(since: start)
        Self.check(gesture, "trackpad gesture")
        #expect(!gesture.isEmpty, "a trackpad gesture wrote no report")

        start = h.io.writes.count
        h.scroll(dx: -30, dy: -4, units: .pixel, phase: .began)
        for _ in 0..<6 { h.scroll(dx: -30, dy: 2, units: .pixel, phase: .changed) }
        h.scroll(dy: 0, units: .pixel, phase: .ended)
        Self.check(try await h.writes(since: start), "sideways swipe")
    }

    /// A reattach replays the screen into a fresh surface (`TerminalSession.swapSurface`); the
    /// wheel over it must still write whole reports, or none.
    @Test func wheelAfterAReplaySwapWritesWholeReports() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.output(Self.codexModes) { h.reporting }
        let before = h.session.surfaceView
        h.io.send(.replay(Data(("\u{1b}[H\u{1b}[2J" + Self.codexModes + "Ask Codex").utf8)))
        try await h.wait { h.session.surfaceView !== before && h.reporting }
        h.move(to: h.middle)
        let start = h.io.writes.count
        for _ in 0..<3 { h.scroll(dy: -1, units: .line) }
        h.scroll(dy: -6, units: .pixel, phase: .began)
        for _ in 0..<8 { h.scroll(dy: -23, units: .pixel, phase: .changed) }
        h.scroll(dy: 0, units: .pixel, phase: .ended)
        Self.check(try await h.writes(since: start), "after replay swap")
    }

    /// Codex quits and turns the modes off: the wheel must write nothing to the shell.
    @Test func wheelAfterTheProgramTurnsMouseOffWritesNothing() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.output(Self.codexModes) { h.reporting }
        try await h.output("\u{1b}[<u\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?1004l\u{1b}[?2004l\u{1b}[?1049l") { !h.reporting }
        h.move(to: h.middle)
        let start = h.io.writes.count
        for _ in 0..<3 { h.scroll(dy: -1, units: .line) }
        h.scroll(dy: -6, units: .pixel, phase: .began)
        for _ in 0..<8 { h.scroll(dy: -23, units: .pixel, phase: .changed) }
        h.scroll(dy: 0, units: .pixel, phase: .ended)
        let writes = try await h.writes(since: start)
        Self.check(writes, "mouse off")
        #expect(writes.isEmpty, "the wheel wrote to a program that turned mouse reports off")
    }
}
