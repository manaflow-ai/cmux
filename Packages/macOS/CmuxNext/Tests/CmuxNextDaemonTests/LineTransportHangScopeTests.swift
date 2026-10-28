import CmuxNextCompat
@testable import CmuxNextTrace
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The reader watches its handling of each line for 100 ms and never its wait in `read(2)`
/// (plans/cmux-next/chrome-parity/p02-threads.md, task 017). A fixture bridge sends one event, waits
/// for a line from the app, sends a second and exits. The counts are read at close, after the reader
/// saw EOF: two lines give exactly two scopes and none still open, where a scope around `read(2)`
/// would give a third enter (the read that saw EOF) or a scope left open. The app's one line, sent from the
/// decode lane's worker thread to an idle writer, goes out inline on that thread: no drain step,
/// so no `daemon.write` scope (p09-observability-069 scopes each drain step; SocketWriterHangScopeTests).
/// Each event's handler and the close run on the connection's decode lane, each in one
/// `daemon.decode` scope.
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
        transport.start(onEvent: { name, _, _ in see.yield(.event(name: name, open: hangs.open("daemon.decode"))) },
                        onClose: { _ in
                            see.yield(.closed(entered: hangs.entered("daemon.line"), open: hangs.open("daemon.line")))
                            see.finish()
                        })
        defer { transport.close() }
        var iterator = seen.makeAsyncIterator()
        let decode = ScopeStackHangWatch.Scope(name: "daemon.decode", deadline: DecodeLane.hangDeadline)

        guard case .event(let first, let firstOpen) = try #require(await iterator.next()) else {
            Issue.record("closed before the first event")
            return
        }
        #expect(first == "first")
        #expect(firstOpen == [decode], "a control event decoded off its lane")
        #expect(transport.sendLine(Data("{}".utf8)))
        guard case .event(let second, let secondOpen) = try #require(await iterator.next()) else {
            Issue.record("closed before the second event")
            return
        }
        #expect(second == "second")
        #expect(secondOpen == [decode])
        guard case .closed(let entered, let open) = try #require(await iterator.next()) else {
            Issue.record("a third event before EOF")
            return
        }

        #expect(entered == 2)
        #expect(open.isEmpty, "the close ran on the lane while the reader was still in a line")
        #expect(hangs.entered("daemon.decode") == 3, "two events and the close")
        #expect(hangs.lanes == ["daemon.write", "daemon.line", "daemon.decode"])
        #expect(hangs.entered("daemon.write") == 0, "the app's one line to an idle writer took a drain step")
    }
}

/// A HangWatchScoping that keeps the open scopes of each lane as one stack (each lane is serial: the reader is
/// one thread, the writer one serial queue).
final class ScopeStackHangWatch: HangWatchScoping {
    struct Scope: Equatable, Sendable {
        var name: String
        var deadline: Duration
    }

    private struct State {
        var lanes: [String] = []
        var open: [String: [Scope]] = [:]
        var entered: [String: Int] = [:]
    }

    private let state = Mutex(State())

    var lanes: [String] { state.withLock { $0.lanes } }
    /// The open scopes of lane `name`, outermost first.
    func open(_ name: String) -> [Scope] { state.withLock { $0.open[name] ?? [] } }
    /// How many scopes lane `name` opened so far.
    func entered(_ name: String) -> Int { state.withLock { $0.entered[name] ?? 0 } }

    func registerLane(_ name: StaticString) -> HangWatch.Registration {
        state.withLock { state in
            state.lanes.append(name.description)
            return HangWatch.Registration(slot: UInt32(state.lanes.count - 1), generation: 1)
        }
    }

    func unregister(_ registration: HangWatch.Registration) {}

    func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T {
        let name = state.withLock { state -> String in
            let name = state.lanes[Int(registration.slot)]
            state.open[name, default: []].append(Scope(name: name, deadline: deadline))
            state.entered[name, default: 0] += 1
            return name
        }
        defer { state.withLock { state in _ = state.open[name]?.removeLast() } }
        return try body()
    }
}
