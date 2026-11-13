import Foundation
import Testing
@testable import CmuxNextDaemon

/// The Requests/Shell family on the wire: the exact JSON line each request sends (the envelope's `id`
/// and `cmd` included), the capability that gates it, and how its reply decodes. The requests are
/// generated from cmux-tui/spec/sdk-schema.json; these hold the JSON the hand-written types sent.
struct ShellRequestWireTests {
    private func line(_ request: some DaemonRequest, id: UInt64 = 1) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: id))
    }

    private func envelope(_ command: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging(["id": .number(1), "cmd": .string(command)]) { $1 })
    }

    @Test func aRunSendsItsCommandFolderScopeAndID() throws {
        #expect(try line(ShellRunRequest(command: "git status", cwd: "/repo/a", scope: "chat", run: "run_0a")) ==
            envelope("shell-run", [
                "command": .string("git status"), "cwd": .string("/repo/a"), "scope": .string("chat"),
                "run": .string("run_0a"),
            ]))
        #expect(try line(ShellRunRequest(command: "ls", cwd: nil, scope: "chat")) ==
            envelope("shell-run", ["command": .string("ls"), "scope": .string("chat")]))
        #expect(ShellRunRequest.requiredCapability == "shell-runs-v1")
    }

    @Test func aReadSendsTheRunAndTheOffsetEvenAtZero() throws {
        #expect(try line(ShellReadRequest(run: "run_0a", after: 0)) ==
            envelope("shell-read", ["run": .string("run_0a"), "after": .number(0)]))
        #expect(try line(ShellReadRequest(run: "run_0a", after: 512)) ==
            envelope("shell-read", ["run": .string("run_0a"), "after": .number(512)]))
        #expect(ShellReadRequest.requiredCapability == "shell-runs-v1")
        #expect(ShellReadRequest.timeout == .seconds(20))
    }

    @Test func aStopSendsOnlyTheRun() throws {
        #expect(try line(ShellStopRequest(run: "run_0a")) == envelope("shell-stop", ["run": .string("run_0a")]))
        #expect(ShellStopRequest.requiredCapability == "shell-runs-v1")
    }

    @Test func theRepliesDecodeARunARefusalAndAnExit() throws {
        let started = try JSONDecoder().decode(ShellRunRequest.Response.self, from: Data(#"{"run":"run_0a"}"#.utf8))
        #expect(started.run == "run_0a")
        #expect(started.refused == nil)
        let refused = try JSONDecoder().decode(ShellRunRequest.Response.self, from: Data(#"{"refused":"too_many"}"#.utf8))
        #expect(refused.refused == "too_many")
        let read = try JSONDecoder().decode(ShellReadRequest.Response.self, from: Data(
            #"{"output":"hi\n","next":3,"truncated":false,"exit":{"code":0,"signal":null}}"#.utf8))
        #expect(read.output == "hi\n")
        #expect(read.next == 3)
        #expect(read.exit == ShellReadRequest.Response.Exit(code: 0, signal: nil))
        let stopped = try JSONDecoder().decode(ShellStopRequest.Response.self, from: Data(#"{}"#.utf8))
        #expect(stopped.refused == nil)
    }

    @Test func aRunIDIsTheDaemonsForm() {
        let id = ShellRunRequest.newRunID()
        #expect(id.hasPrefix("run_"))
        #expect(id.count == 36)
        #expect(id.dropFirst(4).allSatisfy { "0123456789abcdef".contains($0) })
    }
}
