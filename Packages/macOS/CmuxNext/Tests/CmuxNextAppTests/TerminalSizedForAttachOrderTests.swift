import AppKit
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// "Sized for" sometimes did not show (user, Nov 7). A restored tab (relaunch, reopened tab) says
/// `restoring` and a re-attach says `disconnected` while it attaches; the daemon's size state can
/// reach the view in that window, before the replay makes the link `connected`. The view dropped
/// the notice then and showed nothing once connected, until the grid changed again. The view now
/// keeps the latest notice of its link and shows it when the link is connected.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalSizedForAttachOrderTests {
    private static let phone = TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                                grid: TerminalGridSize(columns: 54, rows: 44))
    private static let phoneText = "Sized for Maya's iPhone · 54×44"

    private func session() throws -> (TerminalSession, ScriptedTerminalIO, NSWindow) {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        return (session, io, window)
    }

    /// Sends `events` and returns once the session handled the last of them: it asked for the next.
    private func deliver(_ events: [TerminalIOEvent], to io: ScriptedTerminalIO, _ session: TerminalSession) async throws {
        events.forEach(io.send)
        let handled = await io.waitUntilAllHandled()
        try #require(handled, "the session stopped taking events")
    }

    @Test func aRestoredTabShowsTheNoticeThatCameBeforeItConnected() async throws {
        let (session, io, window) = try session()
        defer { io.finish(); window.close() }
        try await deliver([.status(.restoring), .sizedFor(Self.phone), .status(.connected)], to: io, session)
        #expect(session.view.sizedForText == Self.phoneText)
    }

    @Test func aReattachShowsTheNoticeThatCameBeforeItConnected() async throws {
        let (session, io, window) = try session()
        defer { io.finish(); window.close() }
        try await deliver([.status(.disconnected(.connectionLost, reconnecting: true)), .sizedFor(Self.phone),
                           .status(.connected)], to: io, session)
        #expect(session.view.sizedForText == Self.phoneText)
    }

    @Test func aDroppedLinkForgetsItsNotice() async throws {
        let (session, io, window) = try session()
        defer { io.finish(); window.close() }
        try await deliver([.sizedFor(Self.phone)], to: io, session)
        #expect(session.view.sizedForText == Self.phoneText)
        try await deliver([.status(.disconnected(.connectionLost, reconnecting: true))], to: io, session)
        #expect(session.view.sizedForText == nil)
        // The new link says nothing about sizing (a daemon without shared sizing): no stale chip.
        try await deliver([.status(.connected)], to: io, session)
        #expect(session.view.sizedForText == nil)
        // The new link's own notice shows; its "fits" hides it.
        try await deliver([.sizedFor(Self.phone)], to: io, session)
        #expect(session.view.sizedForText == Self.phoneText)
        try await deliver([.sizedFor(nil)], to: io, session)
        #expect(session.view.sizedForText == nil)
    }
}

/// A scripted ``TerminalIO``: the test sends its events and learns when the session handled them
/// (the session handles events one at a time and only then asks for the next).
private nonisolated final class ScriptedTerminalIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let input: AsyncStream<TerminalIOEvent>.Continuation
    private let pulled: AsyncStream<Void>.Continuation
    private let pulls: PullCounter

    init() {
        let (source, input) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
        let (pullStream, pulled) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        let box = IteratorBox(source.makeAsyncIterator())
        events = AsyncStream(unfolding: {
            pulled.yield()
            return await box.next()
        })
        self.input = input
        self.pulled = pulled
        pulls = PullCounter(pullStream)
    }

    func send(_ event: TerminalIOEvent) {
        pulls.sent()
        input.yield(event)
    }

    func finish() {
        input.finish()
        pulled.finish()
    }

    /// True once the session asked for the event after the last one sent (so it handled them all).
    func waitUntilAllHandled() async -> Bool { await pulls.waitUntilAllHandled() }

    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
}

// Test-only: the session's single consumer task is the only caller of `next()`.
private nonisolated final class IteratorBox: @unchecked Sendable {
    private var iterator: AsyncStream<TerminalIOEvent>.Iterator
    init(_ iterator: AsyncStream<TerminalIOEvent>.Iterator) { self.iterator = iterator }
    func next() async -> TerminalIOEvent? { await iterator.next() }
}

/// Counts the session's pulls against the events sent: pull `n + 1` means events `1...n` were handled.
// Test-only: the test's main actor is the only caller of `sent()` and `waitUntilAllHandled()`, one at a time.
private nonisolated final class PullCounter: @unchecked Sendable {
    private var iterator: AsyncStream<Void>.Iterator
    private var pulled = 0
    private var sentCount = 0

    init(_ pulls: AsyncStream<Void>) { iterator = pulls.makeAsyncIterator() }

    func sent() { sentCount += 1 }

    func waitUntilAllHandled() async -> Bool {
        let target = sentCount + 1
        while pulled < target {
            guard await iterator.next() != nil else { return false }
            pulled += 1
        }
        return true
    }
}
