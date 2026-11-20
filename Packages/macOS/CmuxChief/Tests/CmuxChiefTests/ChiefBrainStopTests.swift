@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// Stop racing a starting turn, and approvals that arrive when no turn may run.
@Suite struct ChiefBrainStopTests {
    private let conversation = ConversationID("c1")

    private func request() -> ChiefTurnRequest {
        ChiefTurnRequest(conversation: conversation, resumeSession: nil, userText: "hi", attachmentPaths: [],
                         replyContext: nil, systemPrompt: "", workingDirectory: FileManager.default.temporaryDirectory,
                         environment: [:])
    }

    private func collect(_ stream: AsyncThrowingStream<ChiefTurnEvent, any Error>) async throws -> [ChiefTurnEvent] {
        var events: [ChiefTurnEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    // MARK: Pending turns

    @Test func stopBeforeClaimCancelsOnlyThatConversationsTurns() {
        let pending = ChiefPendingTurns()
        let mine = UUID(), other = UUID()
        pending.register(mine, conversation: conversation)
        pending.register(other, conversation: ConversationID("c2"))
        pending.stop(conversation: conversation)
        #expect(pending.claim(mine) == false)
        #expect(pending.claim(other) == true)
        // A claimed turn cannot be claimed again.
        #expect(pending.claim(other) == false)
    }

    @Test func stopAfterClaimLeavesTheStartedTurnAndLaterTurnsAlone() {
        let pending = ChiefPendingTurns()
        let first = UUID()
        pending.register(first, conversation: conversation)
        #expect(pending.claim(first))
        pending.stop(conversation: conversation)
        let next = UUID()
        pending.register(next, conversation: conversation)
        #expect(pending.claim(next))
    }

    @Test func consumerLeavingBeforeTheStartCancelsTheTurn() {
        let pending = ChiefPendingTurns()
        let token = UUID()
        pending.register(token, conversation: conversation)
        pending.stop(token)
        #expect(pending.claim(token) == false)
    }

    /// A Stop that arrived before the turn reached its conversation: the
    /// turn must not launch anything. `/usr/bin/false` as the executable
    /// would make a launched turn fail visibly.
    @Test func claudeTurnStoppedBeforeItStartsLaunchesNothing() async throws {
        let pending = ChiefPendingTurns()
        let token = UUID()
        pending.register(token, conversation: conversation)
        pending.stop(conversation: conversation)
        let session = ClaudeConversation(configuration: .init(model: "m", executableOverride: URL(fileURLWithPath: "/usr/bin/false")))
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChiefTurnEvent.self, throwing: (any Error).self)
        await session.start(request(), token: token, continuation: continuation, pending: pending)
        #expect(try await collect(stream).isEmpty)
    }

    @Test func codexTurnStoppedBeforeItStartsLaunchesNothing() async throws {
        let pending = ChiefPendingTurns()
        let token = UUID()
        pending.register(token, conversation: conversation)
        pending.stop(conversation: conversation)
        let session = CodexConversation(configuration: .init(model: "m", executableOverride: URL(fileURLWithPath: "/usr/bin/false")))
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChiefTurnEvent.self, throwing: (any Error).self)
        await session.start(request(), token: token, continuation: continuation, pending: pending)
        #expect(try await collect(stream).isEmpty)
    }

    // MARK: Approvals without a running turn

    @Test func claudeDeniesEvenSafeToolsWithoutARunningTurn() {
        let input: ChiefJSON = ["query": "swift"]
        #expect(ClaudeConversation.permissionDecision(tool: "WebSearch", input: input, turnRunning: true) == .allow)
        #expect(ClaudeConversation.permissionDecision(tool: "WebSearch", input: input, turnRunning: false) == .deny)
        #expect(ClaudeConversation.permissionDecision(tool: "Write", input: ["file_path": "/tmp/x"], turnRunning: true) == .ask)
    }

    @Test func codexDeniesEvenSafeCommandsWithoutARunningTurn() {
        let safe = "/bin/zsh -lc 'cmux list-workspaces'"
        #expect(CodexAppServerBrain.approvalDecision(command: safe, turnRunning: true) == .allow)
        #expect(CodexAppServerBrain.approvalDecision(command: safe, turnRunning: false) == .deny)
        #expect(CodexAppServerBrain.approvalDecision(command: nil, turnRunning: false) == .deny)
        #expect(CodexAppServerBrain.approvalDecision(command: nil, turnRunning: true) == .ask)
    }

    /// A stopped turn's `can_use_tool` that arrives after the next prompt was
    /// written (before its echo) belongs to the stopped turn: deny it.
    @Test func claudePermissionFromAStoppedTurnIsStale() {
        var parser = ClaudeStreamParser(sessionID: "s")
        parser.beginTurn(echo: "a")
        parser.abandonTurn()
        parser.beginTurn(echo: "b")
        let ask = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf x"}}}"#
        let stale = parser.consume(Data(ask.utf8))
        #expect(stale == [.stalePermission(requestID: "r1", input: ["command": "rm -rf x"])])
        // After the echo, requests are the new turn's.
        _ = parser.consume(Data(#"{"type":"user","uuid":"b","isReplay":true,"message":{"content":[]}}"#.utf8))
        let fresh = parser.consume(Data(ask.replacingOccurrences(of: "r1", with: "r2").utf8))
        #expect(fresh == [.permission(requestID: "r2", tool: "Bash", input: ["command": "rm -rf x"])])
    }

    @Test func claudePermissionWithoutATurnIsStale() {
        var parser = ClaudeStreamParser(sessionID: "s")
        let ask = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Read","input":{}}}"#
        #expect(parser.consume(Data(ask.utf8)) == [.stalePermission(requestID: "r1", input: [:])])
    }
}

/// ``ChiefLineProcess`` against small real programs.
@Suite(.timeLimit(.minutes(1))) struct ChiefLineProcessTests {
    private func spawn(_ script: String, grace: DispatchTimeInterval = .milliseconds(200),
                       environment: [String: String] = [:],
                       directory: URL = FileManager.default.temporaryDirectory) throws -> ChiefLineProcess {
        try ChiefLineProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                             environment: environment, workingDirectory: directory, terminationGrace: grace)
    }

    private func write(_ process: ChiefLineProcess, _ text: String) async -> Bool {
        await withCheckedContinuation { done in
            let accepted = process.write(Data(text.utf8)) { done.resume(returning: $0) }
            if !accepted { done.resume(returning: false) }
        }
    }

    @Test func linesRoundTripInOrder() async throws {
        let process = try spawn("exec /bin/cat")
        #expect(await write(process, "one\n"))
        #expect(await write(process, "two\n"))
        var lines: [String] = []
        for await line in process.lines {
            lines.append(String(decoding: line, as: UTF8.self))
            if lines.count == 2 { process.terminate() }
        }
        #expect(lines == ["one", "two"])
        #expect(process.write(Data("late\n".utf8)) == false)
    }

    @Test func runsInItsDirectoryWithItsEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try spawn(#"/bin/pwd -P; echo "$CHIEF_PROBE""#, environment: ["CHIEF_PROBE": "yes"], directory: directory)
        var lines: [String] = []
        for await line in process.lines { lines.append(String(decoding: line, as: UTF8.self)) }
        #expect(lines.count == 2)
        #expect(URL(fileURLWithPath: lines.first ?? "").resolvingSymlinksInPath() == directory.resolvingSymlinksInPath())
        #expect(lines.last == "yes")
    }

    /// A multi-MB line to a child that never reads must not block the
    /// caller; once the child is killed the write fails with EPIPE.
    @Test func largeWriteToAStuckChildDoesNotBlockAndFailsAfterTermination() async throws {
        let process = try spawn(#"trap "" TERM; exec /bin/sleep 600"#)
        let big = Data(repeating: UInt8(ascii: "x"), count: 8 << 20) + Data("\n".utf8)
        let result = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let accepted = process.write(big) { done.resume(returning: $0) }
            #expect(accepted)
            // Reached only because write returned without waiting for the child.
            process.terminate()
        }
        #expect(result == false)
        for await _ in process.lines {}
    }

    /// The child ignores SIGTERM and has a background child holding stdout:
    /// `lines` ends only when SIGKILL reached the whole process group.
    @Test func terminateEscalatesToKillingTheProcessGroup() async throws {
        let process = try spawn(#"trap "" TERM; /bin/sleep 600 & exec /bin/sleep 600"#)
        process.terminate()
        for await _ in process.lines {}
    }
}
