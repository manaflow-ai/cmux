import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The pixel matrix's PTY stills (#45266, row 1 claude-code at 12460 ms; row 4 bash unicode): the
/// phone (53x40) attached to a terminal another device keeps at 100x32, and the attach's replay
/// sat 8 rows (40 - 32) above the cursor the replay put back, so the bytes after it drew under a
/// stale, half-scrolled screen. It came and went from run to run.
///
/// The screen turns the attach's reset (`ESC c`) into the line feeds that put the Mac's first
/// row under its taller mirror's (`TerminalRowShift`), for the grid it knows when it feeds the
/// reset. The session showed the reset before the `vt-state`'s grid: a screen that fed it at
/// once used the phone's own 40 rows, one that fed it a frame later used the Mac's 32.
///
/// `MirrorFeed` feeds the session's events the way `TerminalViewController`'s output pump does
/// (the grid as of the bytes fed, else the session's; `TerminalRowShift`), at once or after the
/// attach, and follows the rows the bytes land on.
@MainActor @Suite struct DaemonTerminalAttachGridTests {
    /// The phone's mirror: its rows plus scroll margins, taller than either grid.
    static let mirrorRows = 60
    /// The Mac's grid, set by another device.
    static let mac = (columns: 100, rows: 32)
    /// The phone's own grid, which it claims.
    static let phone = (columns: 53, rows: 40)
    /// A replay as the Mac's terminal writes it: its first row from wherever the reset left the
    /// cursor, rows down by line feeds, then the cursor put back on its row (`CUP 18;2`).
    static let replay = "MAC-TOP\r\nsecond\r\n\u{1B}[18;2H"

    @Test(arguments: [false, true], [false, true])
    func theAttachReplayLinesUpWithItsCursorAtTheMacsGrid(replayAfterReply: Bool, feedsAtOnce: Bool) async throws {
        let (session, feed) = try await attach(replayAfterReply: replayAfterReply, feedsAtOnce: feedsAtOnce)
        defer { session.stop() }
        expectLinedUp(feed)
    }

    /// The phone's claim went out just before the attach (shown again): the Mac's other grid
    /// and its replay wait in the reclaim hold, then show when the claim is not answered.
    @Test(arguments: [false, true])
    func theAttachReplayHeldForAClaimLinesUpWhenShown(replayAfterReply: Bool) async throws {
        let (session, feed) = try await attach(replayAfterReply: replayAfterReply, feedsAtOnce: true, awaitingClaim: true)
        defer { session.stop() }
        expectLinedUp(feed)
    }

    private func expectLinedUp(_ feed: MirrorFeed) {
        // The Mac's row r is the mirror's row r + (60 - 32).
        let offset = Self.mirrorRows - Self.mac.rows
        #expect(feed.rowOf("MAC-TOP") == 1 + offset, "the replay's first row is the Mac's first row")
        #expect(feed.rowOf("second") == 2 + offset)
        #expect(feed.cursorRow == 18 + offset, "the cursor the replay puts back is on the Mac's row 18")
        #expect(feed.resetFedFor == Self.mac.rows, "the reset was fed for the Mac's rows")
    }

    private func attach(replayAfterReply: Bool, feedsAtOnce: Bool, awaitingClaim: Bool = false) async throws
        -> (DaemonTerminalSession, MirrorFeed) {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        daemon.grid = Self.mac
        daemon.replay = Self.replay
        daemon.replayAfterReply = replayAfterReply
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.reclaimWait = .milliseconds(20)
        session.resize(columns: Self.phone.columns, rows: Self.phone.rows)
        if awaitingClaim {
            session.setClaimsSize(false)
            session.setClaimsSize(true)
        }
        let feed = MirrorFeed(mirrorRows: Self.mirrorRows, feedsAtOnce: feedsAtOnce)
        session.start { [weak session] event in feed.take(event, sessionRows: session?.remoteRows) }
        try await waitUntil { session.isAttached && feed.received.contains("MAC-TOP") }
        // A screen that fed nothing yet feeds what it queued now.
        feed.drain(sessionRows: session.remoteRows)
        return (session, feed)
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

/// The screen's output pump in miniature: `.hostGrid` sets the grid as of the bytes fed
/// (`appliedHostRows`), bytes are shifted for the mirror's rows minus that grid's (else the
/// session's, `feedHostRows`), and the rows they land on are followed (reset, line feed, CUP).
@MainActor
final class MirrorFeed {
    private enum Step { case grid(Int), bytes(Data) }

    let mirrorRows: Int
    let feedsAtOnce: Bool
    private var queue: [Step] = []
    private var appliedRows: Int?
    private var shift = TerminalRowShift()
    private(set) var received = ""
    private(set) var cursorRow = 1
    private(set) var resetFedFor: Int?
    private var rows: [String: Int] = [:]
    private var text = ""
    private var textRow = 1

    init(mirrorRows: Int, feedsAtOnce: Bool) {
        self.mirrorRows = mirrorRows
        self.feedsAtOnce = feedsAtOnce
    }

    func rowOf(_ word: String) -> Int? { rows[word] }

    func take(_ event: TerminalSessionEvent, sessionRows: Int?) {
        switch event {
        case .hostGrid(_, let rows):
            queue.append(.grid(rows))
        case .output(let data):
            received += String(decoding: data, as: UTF8.self)
            queue.append(.bytes(data))
        default:
            return
        }
        if feedsAtOnce { drain(sessionRows: sessionRows) }
    }

    func drain(sessionRows: Int?) {
        while !queue.isEmpty {
            switch queue.removeFirst() {
            case .grid(let rows):
                appliedRows = rows
            case .bytes(let data):
                let remote = appliedRows ?? sessionRows ?? mirrorRows
                if data == TerminalReclaimHold.reset { resetFedFor = remote }
                let shifted = shift.filter(data, offset: max(0, mirrorRows - remote), remoteRows: remote)
                follow(shifted)
            }
        }
    }

    /// Follows the cursor's row through a reset, line feeds and `CUP`, and notes the row each
    /// word of text starts on.
    private func follow(_ data: Data) {
        var bytes = Array(data)[...]
        while let byte = bytes.popFirst() {
            switch byte {
            case 0x1B:
                endWord()
                guard let next = bytes.popFirst() else { return }
                if next == UInt8(ascii: "c") {
                    cursorRow = 1
                } else if next == UInt8(ascii: "[") {
                    var params = ""
                    while let b = bytes.popFirst() {
                        if (0x40...0x7E).contains(b) {
                            if b == UInt8(ascii: "H") || b == UInt8(ascii: "f") {
                                cursorRow = Int(params.split(separator: ";").first ?? "1") ?? 1
                            }
                            break
                        }
                        params.append(Character(UnicodeScalar(b)))
                    }
                }
            case 0x0A:
                endWord()
                cursorRow = min(cursorRow + 1, mirrorRows)
            case 0x0D:
                endWord()
            default:
                if text.isEmpty { textRow = cursorRow }
                text.append(Character(UnicodeScalar(byte)))
            }
        }
        endWord()
    }

    private func endWord() {
        if !text.isEmpty, rows[text] == nil { rows[text] = textRow }
        text = ""
    }
}
