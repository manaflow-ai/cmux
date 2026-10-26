import CmuxNextCompat
@testable import CmuxNextTrace
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The reader watches its handling of each line for 100 ms and never its wait in `read(2)`
/// (plans/cmux-next/chrome-parity/p02-threads.md, task 017). A fixture bridge sends one event, waits
/// for a line from the app, sends a second and exits. The counts are read at close, after the reader
/// saw EOF: two lines give exactly two scopes and none still open, where a scope around `read(2)`
/// would give a third enter (the read that saw EOF) or a scope left open.
@Suite(.timeLimit(.minutes(1))) struct LineTransportHangScopeTests {
    enum Seen: Sendable {
        case event(name: String, open: [ScopeStackHangWatch.Scope])
        case closed(entered: Int, open: [ScopeStackHangWatch.Scope])
    }

    @Test func eachLineIsOneScopeAndTheReadWaitIsNone() async throws {
        let script = #"""
        import sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        print('{"event":"first"}', flush=True)
        sys.stdin.readline()
        print('{"event":"second"}', flush=True)
        """#
        let hangs = ScopeStackHangWatch()
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        let transport = try await LineTransport.open(path: "/tmp/cmux-hang-scope-\(UUID().uuidString).sock", bridge: bridge, role: .control,
                                                     stats: nil, hangs: hangs)
        let (seen, see) = AsyncStream.makeStream(of: Seen.self)
        transport.start(onEvent: { name, _, _ in see.yield(.event(name: name, open: hangs.open)) },
                        onClose: { _ in
                            see.yield(.closed(entered: hangs.entered, open: hangs.open))
                            see.finish()
                        })
        defer { transport.close() }
        var iterator = seen.makeAsyncIterator()
        let line = ScopeStackHangWatch.Scope(name: "daemon.line", deadline: .milliseconds(100))

        guard case .event(let first, let firstOpen) = try #require(await iterator.next()) else {
            Issue.record("closed before the first event")
            return
        }
        #expect(first == "first")
        #expect(firstOpen == [line])
        #expect(transport.sendLine(Data("{}".utf8)))
        guard case .event(let second, let secondOpen) = try #require(await iterator.next()) else {
            Issue.record("closed before the second event")
            return
        }
        #expect(second == "second")
        #expect(secondOpen == [line])
        guard case .closed(let entered, let open) = try #require(await iterator.next()) else {
            Issue.record("a third event before EOF")
            return
        }

        #expect(entered == 2)
        #expect(open.isEmpty)
        #expect(hangs.lanes == ["daemon.line"])
    }
}

/// A HangWatchScoping that keeps the open scopes as one stack (the reader is one thread).
final class ScopeStackHangWatch: HangWatchScoping {
    struct Scope: Equatable, Sendable {
        var name: String
        var deadline: Duration
    }

    private struct State {
        var lanes: [String] = []
        var open: [Scope] = []
        var entered = 0
    }

    private let state = Mutex(State())

    var lanes: [String] { state.withLock { $0.lanes } }
    var open: [Scope] { state.withLock { $0.open } }
    var entered: Int { state.withLock { $0.entered } }

    func registerLane(_ name: StaticString) -> HangWatch.Registration {
        state.withLock { state in
            state.lanes.append(name.description)
            return HangWatch.Registration(slot: UInt32(state.lanes.count - 1), generation: 1)
        }
    }

    func unregister(_ registration: HangWatch.Registration) {}

    func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T {
        state.withLock { state in
            state.open.append(Scope(name: state.lanes[Int(registration.slot)], deadline: deadline))
            state.entered += 1
        }
        defer { state.withLock { state in _ = state.open.removeLast() } }
        return try body()
    }
}
