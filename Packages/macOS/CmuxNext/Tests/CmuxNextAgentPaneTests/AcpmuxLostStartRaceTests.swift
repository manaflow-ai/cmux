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
    @Test func aLaunchThatLosesTheStartRaceStillKeysTheWinner() async throws {
        let binary = try #require(SameTreeAcpmuxBinary.url)
        let root = URL(fileURLWithPath: "/tmp/alr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = home.appendingPathComponent("s.sock").path
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The app's acpmux, at first a stand-in for this launch: it puts the real binary at its
        // own path, starts it as another client would (the winner, at the path the server peer
        // check expects), waits until it is ready, and exits before writing this launch's ready
        // line, as a launch that found `daemon.lock` taken does.
        try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux-real"))
        let ready = root.appendingPathComponent("winner-ready").path
        let script = """
        #!/bin/sh
        dir=$(dirname "$0")
        mv "$dir/acpmux-real" "$dir/acpmux"
        shift 4
        "$dir/acpmux" daemon run --ready-fd 5 "$@" 5>'\(ready)' 3>&- </dev/null >>"$ACPMUX_LAUNCH_LOG" 2>&1 &
        i=0
        while [ ! -s '\(ready)' ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
        exit 1

        """
        let stand = bin.appendingPathComponent("acpmux")
        try script.write(to: stand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stand.path)
        var environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin,
            environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket],
            executableOverride: nil
        ))
        // A Team-signed app: the daemon gets no key at spawn, only by enroll.
        environment.passesPersonKeyAtSpawn = false

        var started: Result<Void, any Error> = .success(())
        do {
            try await AcpmuxHost(environment: environment).prewarm()
        } catch {
            started = .failure(error)
        }
        let winner = try? await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15))
        let key = AcpmuxPersonKey.proof(socketPath: socket, transport: .app, nonce: "nonce", connection: "connection")
        // Whatever failed, the daemon this test started ends with it.
        _ = try? await AcpmuxStatusClient.shutdown(socketPath: socket, home: home, deadline: .seconds(10))
        if case .failure(let error) = started {
            let log = (try? String(contentsOf: home.appendingPathComponent("daemon.log"), encoding: .utf8))
                .map { $0.split(separator: "\n").suffix(30).joined(separator: "\n") } ?? "no daemon.log"
            Issue.record("the pane did not reach the winner: \(error)\n--- daemon.log\n\(log)")
            return
        }
        #expect(winner != nil, "no daemon won the start")
        #expect(FileManager.default.fileExists(atPath: ready), "the stand-in did not start the winner")
        #expect(key != nil, "the app used the daemon that won the start without enrolling its person key: no pane proves the person, and every Allow is refused until the app restarts")
    }
}
