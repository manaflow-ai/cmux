@testable import CmuxNextCloud
import Foundation
import Testing

/// ``CloudCarrierServe/dialAhead(limit:keep:)``: the app's edge of a dial made ahead of a session. The app asks the
/// supervisor with one `ahead` line and reads the outcome from the lines every connection gets; the connection itself
/// is the supervisor's (cmux-tui `carrier/supervise.rs`, whose tests cover its hold and its drops). A shell stand-in
/// speaks the supervisor's lines (as in ``CloudCarrierServeEdgeTests``), keeps every line it was sent in `stdin`, and
/// says whatever line the test writes to its `say` pipe. Nothing here blocks a thread: each wait asks without waiting
/// and yields between asks.
@Suite struct CloudCarrierServeAheadTests {
    /// The stand-in supervisor: a connect is answered with the socket and no connected line; each line written to
    /// `say` beside it goes out as one of its own.
    private static func standIn() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cca-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("cmux-tui")
        let body = """
        #!/bin/sh
        d=$(dirname "$0")
        mkfifo "$d/say"
        ( while :; do while IFS= read -r w; do printf '%s\\n' "$w" >&2; done < "$d/say"; done ) &
        say=$!
        trap 'kill $say 2>/dev/null' EXIT
        while IFS= read -r l; do
          printf '%s\\n' "$l" >> "$d/stdin"
          case "$l" in
            *'"connect"'*) n=$(printf '%s' "$l" | sed 's/.*"connect":\\([0-9]*\\).*/\\1/'); printf '{"read_token":%s}\\n' "$n" >&2 ;;
            *'"token"'*) n=$(printf '%s' "$l" | sed 's/.*"token":\\([0-9]*\\).*/\\1/'); printf '{"resume":[%s],"socket":"%s"}\\n' "$n" "$6" >&2 ;;
            *'"stop"'*|*'"account_ended"'*) exit 0 ;;
          esac
        done
        """
        try body.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    /// A serve whose socket is `socket`: nothing listens there, and nothing here connects to it.
    private static func serve(_ cli: URL, socket: String = "/tmp/cca-\(UUID().uuidString.prefix(8)).sock") throws -> CloudCarrierServe {
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))
        return CloudCarrierServe(connector: .init(cli: cli, dial: dial) { ["CMUX_CLOUD_ACCESS_TOKEN": "t-1"] }, socket: socket)
    }

    /// One supervisor line, through the stand-in's `say` pipe (opened without waiting for its reader, asked again
    /// until the stand-in reads). The caller closes the returned pipe after the line took effect: a writer still
    /// open when the reader wakes is what every FIFO implementation hands the line to.
    private static func say(_ cli: URL, _ line: String) async throws -> Int32 {
        let path = cli.deletingLastPathComponent().appendingPathComponent("say").path
        let deadline = ContinuousClock.now + .seconds(5)
        var pipe = open(path, O_WRONLY | O_NONBLOCK)
        while pipe < 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            pipe = open(path, O_WRONLY | O_NONBLOCK)
        }
        try #require(pipe >= 0, "the stand-in reads its say pipe")
        let bytes = Array((line + "\n").utf8)
        #expect(write(pipe, bytes, bytes.count) == bytes.count)
        return pipe
    }

    /// The `ahead` lines the stand-in was sent so far, each as its object.
    private static func asks(_ cli: URL) -> [[String: Any]] {
        let sent = (try? String(contentsOf: cli.deletingLastPathComponent().appendingPathComponent("stdin"), encoding: .utf8)) ?? ""
        return sent.split(whereSeparator: \.isNewline).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }.filter { $0["ahead"] != nil }
    }

    /// The first `ahead` line the stand-in gets, nil when none comes within five seconds.
    private static func asked(_ cli: URL) async -> [String: Any]? {
        let deadline = ContinuousClock.now + .seconds(5)
        while asks(cli).isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return asks(cli).first
    }

    /// The dial is one `ahead` line with its keep; the serve's connected line is its answer.
    @Test func aDialAheadAsksTheSupervisorAndTheServesConnectedLineAnswersIt() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let serve = try Self.serve(cli)
        _ = try await serve.socketPath()
        async let dialed = serve.dialAhead(limit: .seconds(5), keep: .seconds(60))
        let ask = try #require(await Self.asked(cli))
        #expect(ask["ahead"] as? UInt64 != nil)
        #expect(ask["keep_ms"] as? Int == 60_000)
        let said = try await Self.say(cli, #"{"publish":"owner"}"#)
        defer { close(said) }
        #expect(await dialed)
        #expect(await serve.answer == .owner)
        #expect(Self.asks(cli).count == 1, "one line per dial")
        await serve.stop()
    }

    /// A connected answer in a `state` line answers the dial too (a session connected while the dial ran).
    @Test func aStateWithAnAnswerAnswersTheDial() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let serve = try Self.serve(cli)
        _ = try await serve.socketPath()
        async let dialed = serve.dialAhead(limit: .seconds(5), keep: .seconds(60))
        _ = try #require(await Self.asked(cli))
        _ = try await serve.socketPath()
        let said = try await Self.say(cli, #"{"state":{"refusal":null,"answer":"owner"}}"#)
        defer { close(said) }
        #expect(await dialed)
        await serve.stop()
    }

    /// A refused dial answers false, and the refusal is the link's.
    @Test func aRefusedDialAheadAnswersFalse() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let serve = try Self.serve(cli)
        _ = try await serve.socketPath()
        async let dialed = serve.dialAhead(limit: .seconds(5), keep: .seconds(60))
        _ = try #require(await Self.asked(cli))
        let said = try await Self.say(cli, #"{"state":{"refusal":{"kind":"not_up","state":"parked_timeout"},"answer":null}}"#)
        defer { close(said) }
        #expect(await dialed == false)
        #expect(await serve.refusal == .notUp(state: "parked_timeout"))
        await serve.stop()
    }

    /// The supervisor holds no connection for the dial (no child serves yet, or one is held): false at once.
    @Test func aDialTheSupervisorDoesNotHoldAnswersFalseAtOnce() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let serve = try Self.serve(cli)
        _ = try await serve.socketPath()
        let began = ContinuousClock.now
        async let dialed = serve.dialAhead(limit: .seconds(30), keep: .seconds(60))
        let ask = try #require(await Self.asked(cli))
        let dial = try #require(ask["ahead"] as? UInt64)
        let said = try await Self.say(cli, #"{"ahead":\#(dial),"held":false}"#)
        defer { close(said) }
        #expect(await dialed == false)
        #expect(began.duration(to: .now) < .seconds(20), "answered by the supervisor's line, not by the limit")
        await serve.stop()
    }

    /// No answer within the limit: false. The supervisor still holds its connection (the dial goes on in the serve).
    @Test func aDialAheadWithNoAnswerInTimeAnswersFalse() async throws {
        let cli = try Self.standIn()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let serve = try Self.serve(cli)
        _ = try await serve.socketPath()
        #expect(await serve.dialAhead(limit: .milliseconds(50), keep: .seconds(60)) == false)
        #expect(await Self.asked(cli) != nil, "the supervisor was asked")
        await serve.stop()
    }

    /// A serve that is not up (no connect asked for its socket yet), or stopped, asks nothing and starts nothing.
    @Test func aServeThatIsNotUpOrIsStoppedAsksNothing() async throws {
        let cli = try Self.standIn()
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let serve = try Self.serve(cli)
        #expect(await serve.dialAhead(limit: .seconds(1), keep: .seconds(60)) == false)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stdin").path), "no supervisor started")
        _ = try await serve.socketPath()
        await serve.stop()
        #expect(await serve.dialAhead(limit: .seconds(1), keep: .seconds(60)) == false)
        #expect(Self.asks(cli).isEmpty, "no dial was asked")
    }
}
