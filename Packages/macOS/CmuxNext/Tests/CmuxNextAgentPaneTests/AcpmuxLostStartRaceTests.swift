import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A launch that loses the start race to another client (Leo, 2026-10-24: "clicking the allow
/// buttons didn't do anything. Restarting it did something."). On cosmic-gray the app handed off
/// an old daemon after an update; its own launch exited because the old one still held
/// `daemon.lock`, and the daemon that won took the socket. The app then used the winner without
/// enrolling its person key: a signed daemon gets the key only from `_acpmux/person_enroll`, so
/// every pane connected without a proof ("no person key for this daemon; allows stay refused"),
/// and each Allow came back "Only the cmux app can approve this" until the app relaunched.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeAcpmuxBinary.url != nil, "needs the same-tree acpmux"))
struct AcpmuxLostStartRaceTests {
    /// The app's acpmux is at first a stand-in for this launch: it puts the real binary at its own
    /// path, starts it as another client would (the winner, at the path the server peer check
    /// expects; with `winnerHome`, as another app's or tag's daemon on the same socket), waits
    /// until it is ready, and exits before writing this launch's ready line, as a launch that
    /// found `daemon.lock` taken does. The app is a Team-signed one: its daemon gets no key at
    /// spawn, only by enroll.
    struct Fixture {
        let root: URL
        let home: URL
        let winnerHome: URL
        let socket: String
        let ready: String
        var environment: AcpmuxEnvironment

        init(winnerOfAnotherHome: Bool) throws {
            let binary = try #require(SameTreeAcpmuxBinary.url)
            root = URL(fileURLWithPath: "/tmp/alr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            winnerHome = winnerOfAnotherHome ? root.appendingPathComponent("other", isDirectory: true) : home
            socket = home.appendingPathComponent("s.sock").path
            ready = root.appendingPathComponent("winner-ready").path
            for directory in [bin, home, winnerHome] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux-real"))
            let script = """
            #!/bin/sh
            dir=$(dirname "$0")
            mv "$dir/acpmux-real" "$dir/acpmux"
            shift 4
            ACPMUX_HOME='\(winnerHome.path)' "$dir/acpmux" daemon run --ready-fd 5 "$@" 5>'\(ready)' 3>&- </dev/null >>"$ACPMUX_LAUNCH_LOG" 2>&1 &
            i=0
            while [ ! -s '\(ready)' ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
            exit 1

            """
            let stand = bin.appendingPathComponent("acpmux")
            try script.write(to: stand, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stand.path)
            environment = try #require(AcpmuxEnvironment.resolve(
                build: nil, bundledBinDirectory: bin,
                environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket],
                executableOverride: nil
            ))
            environment.passesPersonKeyAtSpawn = false
        }

        /// The key the app would prove a pane with on this socket, if it holds one.
        var key: String? {
            AcpmuxPersonKey.proof(socketPath: socket, transport: .app, nonce: "nonce", connection: "connection")
        }

        /// Stops the winner and waits for it to exit (killing it if it outlives that), then
        /// removes the folders. Only the daemon this fixture's stand-in started is signalled.
        func remove(winner pid: Int32?) async {
            _ = try? await AcpmuxStatusClient.shutdown(socketPath: socket, home: winnerHome, deadline: .seconds(10))
            let pid = pid ?? (try? String(contentsOf: winnerHome.appendingPathComponent("daemon.pid"), encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let pid, pid > 0 {
                let deadline = ContinuousClock.now + .seconds(10)
                // wakeup-allow: bounded wait (10 s) for the test's own daemon to exit after its shutdown.
                while kill(pid, 0) == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: root)
        }

        func log() -> String {
            (try? String(contentsOf: winnerHome.appendingPathComponent("daemon.log"), encoding: .utf8))
                .map { $0.split(separator: "\n").suffix(30).joined(separator: "\n") } ?? "no daemon.log"
        }
    }

    @Test func aLaunchThatLosesTheStartRaceStillKeysTheWinner() async throws {
        let fixture = try Fixture(winnerOfAnotherHome: false)
        var started: Result<Void, any Error> = .success(())
        do {
            try await AcpmuxHost(environment: fixture.environment).prewarm()
        } catch {
            started = .failure(error)
        }
        let winner = try? await AcpmuxStatusClient.status(socketPath: fixture.socket, deadline: .seconds(15))
        let key = fixture.key
        // The key is the one the app holds for that very daemon instance, not one for another.
        let bound = AcpmuxPersonKey.proof(key: AcpmuxPersonKey.enrollKey(for: fixture.socket, pid: winner?.pid),
                                          transport: .app, nonce: "nonce", connection: "connection")
        let log = fixture.log()
        await fixture.remove(winner: winner?.pid)
        if case .failure(let error) = started {
            Issue.record("the pane did not reach the winner: \(error)\n--- daemon.log\n\(log)")
            return
        }
        #expect(winner?.pid != nil, "no daemon won the start")
        #expect(key != nil, "the app used the daemon that won the start without enrolling its person key: no pane proves the person, and every Allow is refused until the app restarts")
        #expect(bound == key, "the app's key is not bound to the daemon that won the start")
    }

    /// The winner serves another acpmux home on this app's socket (another app's or tag's): the
    /// launch refuses it as the paths that find a daemon running do, and never keys it.
    @Test func aWinnerOfAnotherHomeIsRefusedAndNeverKeyed() async throws {
        let fixture = try Fixture(winnerOfAnotherHome: true)
        var thrown: (any Error)?
        do {
            try await AcpmuxHost(environment: fixture.environment).prewarm()
        } catch {
            thrown = error
        }
        let winner = try? await AcpmuxStatusClient.status(socketPath: fixture.socket, deadline: .seconds(15))
        let key = fixture.key
        let log = fixture.log()
        await fixture.remove(winner: winner?.pid)
        #expect(winner?.serves(home: fixture.winnerHome) == true, "the other home's daemon did not win the start\n--- daemon.log\n\(log)")
        guard case AgentPaneHostError.daemonRefused? = thrown as? AgentPaneHostError else {
            Issue.record("a winner of another home was used: \(String(describing: thrown))")
            return
        }
        #expect(key == nil, "the app enrolled its person key with another home's daemon")
    }
}
