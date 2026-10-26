import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
import Foundation
import Testing

/// The local PTY registers two lanes: each read drain (read until EAGAIN) is one `localpty.read` scope of 1 s
/// and each input flush (write until EAGAIN) one `localpty.write` scope of 2 s; the wait for readiness is in
/// none (plans/cmux-next/chrome-parity/p09-observability.md, section E, task 069). The last drain runs before
/// the stream says `.exited`, so at that event no read scope may still be open.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LocalPTYHangScopeTests {
    @Test func eachDrainAndFlushIsOneScopeAndTheReadinessWaitIsNone() async throws {
        let hangs = PTYLaneScopeLog()
        let io = try LocalPTYTerminalIO(shell: "/bin/sh", workingDirectory: "/", environment: ["PS1": ""],
                                        installedTerminfo: false, hangs: hangs)
        defer { io.terminate() }
        #expect(hangs.lanes == ["localpty.read", "localpty.write"])

        await io.write(Data("echo HANG-SCOPE; exit\n".utf8))
        var output = ""
        var exited = false
        for await event in io.events {
            switch event {
            case .output(let data): output += String(decoding: data, as: UTF8.self)
            case .exited: exited = true
            default: break
            }
            if exited { break }
        }

        #expect(exited)
        #expect(output.contains("HANG-SCOPE"))
        #expect(hangs.open("localpty.read").isEmpty, "a read scope stayed open over the wait for readiness")
        let reads = hangs.entered("localpty.read")
        let writes = hangs.entered("localpty.write")
        #expect(!reads.isEmpty && reads.allSatisfy { $0 == .seconds(1) })
        #expect(!writes.isEmpty && writes.allSatisfy { $0 == .seconds(2) })
    }

    @Test func aDrainHasOneSecondAndAFlushTwo() {
        #expect(LocalPTYTerminalIO.readHangDeadline == .seconds(1))
        #expect(LocalPTYTerminalIO.writeHangDeadline == .seconds(2))
    }
}

/// A HangWatchScoping that records each lane's scopes (their deadlines) and its open ones; the read and the
/// write lane run on two queues, so each lane has its own stack.
final class PTYLaneScopeLog: HangWatchScoping {
    private struct State {
        var lanes: [String] = []
        var open: [String: [Duration]] = [:]
        var entered: [String: [Duration]] = [:]
    }

    private let state = Mutex(State())

    var lanes: [String] { state.withLock { $0.lanes } }
    /// The deadlines of lane `name`'s open scopes, outermost first.
    func open(_ name: String) -> [Duration] { state.withLock { $0.open[name] ?? [] } }
    /// The deadline of each scope lane `name` opened, in order.
    func entered(_ name: String) -> [Duration] { state.withLock { $0.entered[name] ?? [] } }

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
            state.open[name, default: []].append(deadline)
            state.entered[name, default: []].append(deadline)
            return name
        }
        defer { state.withLock { state in _ = state.open[name]?.removeLast() } }
        return try body()
    }
}
