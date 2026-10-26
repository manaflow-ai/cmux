import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The reader watches its handling of each line for 100 ms and never its wait in `read(2)`
/// (plans/cmux-next/chrome-parity/p02-threads.md, task 017). A fixture bridge sends one event,
/// waits for a line from the app, then sends a second: the second event's handler must see only its
/// own scope open, so the first scope ended before the reader went back to `read(2)`.
@Suite(.timeLimit(.minutes(1))) struct LineTransportHangScopeTests {
    @Test func eachLineIsOneScopeAndTheReadWaitIsNone() async throws {
        let script = #"""
        import sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        print('{"event":"first"}', flush=True)
        sys.stdin.readline()
        print('{"event":"second"}', flush=True)
        sys.stdin.readline()
        """#
        let hangs = ScopeStackHangWatch()
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        let transport = try LineTransport(path: "/tmp/cmux-hang-scope-\(UUID().uuidString).sock", bridge: bridge, hangs: hangs)
        let (events, event) = AsyncStream.makeStream(of: (name: String, open: [ScopeStackHangWatch.Scope]).self)
        transport.start(onEvent: { name, _, _ in event.yield((name, hangs.open)) }, onClose: { _ in event.finish() })
        defer { transport.close() }
        var iterator = events.makeAsyncIterator()
        let line = ScopeStackHangWatch.Scope(name: "daemon.line", deadline: .milliseconds(100))

        let first = try #require(await iterator.next())
        #expect(first.name == "first")
        #expect(first.open == [line])
        #expect(transport.sendLine(Data("{}".utf8)))
        let second = try #require(await iterator.next())

        #expect(second.name == "second")
        #expect(second.open == [line])
        #expect(hangs.entered == 2)
    }
}

/// A HangWatching that keeps the open scopes as one stack (the reader is one thread).
final class ScopeStackHangWatch: HangWatching {
    struct Scope: Equatable, Sendable {
        var name: String
        var deadline: Duration
    }

    private struct State {
        var open: [Scope] = []
        var entered = 0
    }

    private let state = Mutex(State())

    var open: [Scope] { state.withLock { $0.open } }
    var entered: Int { state.withLock { $0.entered } }

    func enter(_ name: StaticString, deadline: Duration) -> HangWatchToken {
        state.withLock { state in
            state.open.append(Scope(name: name.description, deadline: deadline))
            state.entered += 1
            return HangWatchToken(slot: 0, previousDeadline: 0)
        }
    }

    func leave(_ token: HangWatchToken) {
        state.withLock { state in _ = state.open.removeLast() }
    }
}
