@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

/// B6 ("tmux first open is sometimes blank, renders after reopen"): pins the
/// order of the tmux control-mode seed so a blank first open cannot come
/// from it. The phone must size the client before seeding, correlate
/// replies only with its own commands (startup blocks carry flag 0), drop
/// `%output` the capture already contains, and deliver the grid, the
/// snapshot, then output that followed the capture, in that order.
@MainActor
@Suite struct MobileSSHTmuxSeedOrderTests {
    /// An in-memory `tmux -C` stream: what the client writes, and what
    /// "tmux" sends back.
    final class Pipe: MobileSSHTmuxControlTransport, @unchecked Sendable {
        let events: AsyncStream<SSHSessionEvent>
        private let eventsContinuation: AsyncStream<SSHSessionEvent>.Continuation
        let written: AsyncStream<Data>
        private let writtenContinuation: AsyncStream<Data>.Continuation

        init() {
            (events, eventsContinuation) = AsyncStream.makeStream(of: SSHSessionEvent.self)
            (written, writtenContinuation) = AsyncStream.makeStream(of: Data.self)
        }

        func write(_ data: Data) async throws { writtenContinuation.yield(data) }
        func close() async { eventsContinuation.yield(.closed) }
        func tmux(_ text: String) { eventsContinuation.yield(.stdout(Data(text.utf8))) }
    }

    enum Seen: Equatable {
        case grid(Int, Int)
        case snapshot(String)
        case output(String)
        case ended
    }

    @Test func seedSizesFirstThenDeliversGridSnapshotAndLaterOutputInOrder() async throws {
        let pipe = Pipe()
        let client = MobileSSHTmuxControlClient(sessionName: "work", groupedSessionName: "work-cmux-ios-test", channel: pipe)
        client.startPump()
        let (events, sink) = AsyncStream.makeStream(of: Seen.self)

        // What MobileSSHTmuxProvider.attach does: size, then seed.
        client.setClientSize(columns: 40, rows: 20)
        client.attach(pane: 1) { event in
            switch event {
            case .remoteGrid(let columns, let rows): sink.yield(.grid(columns, rows))
            case .snapshot(let data): sink.yield(.snapshot(String(decoding: data, as: UTF8.self)))
            case .output(let data): sink.yield(.output(String(decoding: data, as: UTF8.self)))
            case .ended: sink.yield(.ended)
            }
        }

        // Every command reaches tmux in one ordered stream, the size first.
        var sent = ""
        var writes = pipe.written.makeAsyncIterator()
        while !sent.contains("%1:continue") {
            sent += String(decoding: try #require(await writes.next()), as: UTF8.self)
        }
        let commands = sent.split(separator: "\n").map(String.init)
        #expect(commands.map { $0.split(separator: " ").prefix(2).joined(separator: " ") } == [
            "refresh-client -C",
            "refresh-client -A",
            "display-message -p",
            "capture-pane -p",
            "display-message -p",
            "refresh-client -A",
        ])
        #expect(commands[0] == "refresh-client -C 40x20")
        #expect(commands[1] == "refresh-client -A '%1:pause'")

        pipe.tmux("%begin 1 10 0\n%end 1 10 0\n") // startup command block: not ours
        pipe.tmux("%begin 1 11 1\n%end 1 11 1\n") // refresh-client -C
        pipe.tmux("%begin 1 12 1\n%end 1 12 1\n") // pause
        pipe.tmux("%output %1 early\n") // already in the capture
        pipe.tmux("%begin 1 13 1\n0\n%end 1 13 1\n") // alternate_on
        pipe.tmux("%begin 1 14 1\nme@box:~$ ls\nfile.txt\nme@box:~$ \n%end 1 14 1\n") // capture
        pipe.tmux("%output %1 late\n") // after the capture, before the state
        pipe.tmux("%begin 1 15 1\ncursor_x=10,cursor_y=2,cursor_flag=1,wrap_flag=1,pane_width=40,pane_height=20\n%end 1 15 1\n")
        pipe.tmux("%begin 1 16 1\n%end 1 16 1\n") // continue
        pipe.tmux("%output %1 live\n")

        var seen: [Seen] = []
        for await event in events {
            seen.append(event)
            if seen.count == 4 { break }
        }
        guard seen.count == 4, case .snapshot(let snapshot) = seen[1] else {
            Issue.record("unexpected events \(seen)")
            return
        }
        #expect(seen[0] == .grid(40, 20))
        #expect(snapshot.hasPrefix("\u{1B}[H\u{1B}[2Jme@box:~$ ls\r\nfile.txt\r\nme@box:~$ "))
        #expect(snapshot.hasSuffix("\u{1B}[3;11H"))
        #expect(!snapshot.contains("early"))
        #expect(seen[2] == .output("late"))
        #expect(seen[3] == .output("live"))
    }
}
