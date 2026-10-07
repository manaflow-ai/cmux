import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Shell mode's Tab (`shell.complete`): the candidates come from the user's own shell (zsh's
/// completion system, bash's `compgen`, fish's `complete -C`), never from a list in cmux, and a
/// completion runs only after a real gesture in the pane (completion functions run code).
@MainActor
@Suite struct AgentPaneShellCompletionTests {
    /// The shared test deadline: these tests check candidates, not the 4 s app deadline, and a
    /// loaded fleet Mac (load 56 on aws-m4pro-3) took longer than 4 s to start a login bash.
    static let timeout: Duration = .seconds(30)

    private func folder(_ files: [String] = [], directories: [String] = []) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in directories {
            try FileManager.default.createDirectory(at: url.appending(path: name), withIntermediateDirectories: true)
        }
        for name in files { try Data().write(to: url.appending(path: name)) }
        guard let real = realpath(url.path, nil) else { return url.path }
        defer { free(real) }
        return String(cString: real)
    }

    private func values(_ result: AgentPaneShellCompletion.Result) -> [String] { result.candidates.map(\.value) }

    @Test func theWordUnderTheCaretStartsAfterTheLastUnquotedSeparator() {
        typealias C = AgentPaneShellCompletion
        #expect(C.word(in: "") == C.Word(start: 0, text: "", commandPosition: true))
        #expect(C.word(in: "ech") == C.Word(start: 0, text: "ech", commandPosition: true))
        #expect(C.word(in: "git checkout ma") == C.Word(start: 13, text: "ma", commandPosition: false))
        #expect(C.word(in: "git ") == C.Word(start: 4, text: "", commandPosition: false))
        #expect(C.word(in: "ls | gr") == C.Word(start: 5, text: "gr", commandPosition: true))
        #expect(C.word(in: "ls|gr") == C.Word(start: 3, text: "gr", commandPosition: true))
        #expect(C.word(in: "make && ./scr") == C.Word(start: 8, text: "./scr", commandPosition: true))
        #expect(C.word(in: #"cat a\ b"#) == C.Word(start: 4, text: #"a\ b"#, commandPosition: false))
        #expect(C.word(in: #"cat "a b"#) == C.Word(start: 4, text: #""a b"#, commandPosition: false))
        // Offsets are UTF-16, as the page's field counts them.
        #expect(C.word(in: "echo \u{1F642} x") == C.Word(start: 8, text: "x", commandPosition: false))
    }

    @Test func candidatesAreEscapedForTheShellUnlessTheWordIsQuoted() {
        typealias C = AgentPaneShellCompletion
        #expect(C.escape("alpha file.txt", word: "alp") == #"alpha\ file.txt"#)
        #expect(C.escape("a$b(c)", word: "a") == #"a\$b\(c\)"#)
        #expect(C.escape("~/Documents/", word: "~/Doc") == "~/Documents/")
        #expect(C.escape("--color=auto", word: "--co") == "--color=auto")
        #expect(C.escape("alpha file.txt", word: #""alp"#) == #""alpha file.txt"#)
    }

    @Test func zshCompletesCommandsFromItsOwnCommandTable() async throws {
        let completion = AgentPaneShellCompletion(shell: "/bin/zsh", timeout: Self.timeout)
        let result = try await completion.complete("ech", cwd: try folder())
        #expect(result.start == 0)
        #expect(values(result).contains("echo"))
    }

    /// zsh's completion system knows subcommands; a hand-written list would not.
    @Test func zshCompletesSubcommandsThroughItsCompletionSystem() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let completion = AgentPaneShellCompletion(shell: "/bin/zsh", timeout: Self.timeout)
        let result = try await completion.complete("git chec", cwd: try folder())
        #expect(result.start == 4)
        #expect(values(result).contains("checkout"))
    }

    @Test func zshCompletesFilesInTheChatsFolder() async throws {
        let cwd = try folder(["alpha file.txt", "beta.txt"], directories: ["alps"])
        let completion = AgentPaneShellCompletion(shell: "/bin/zsh", timeout: Self.timeout)
        let result = try await completion.complete("cat al", cwd: cwd)
        #expect(result.start == 4)
        #expect(Set(values(result)) == [#"alpha\ file.txt"#, "alps/"])
    }

    @Test func bashCompletesCommandsAndFiles() async throws {
        let cwd = try folder(["alpha.txt"], directories: ["alps"])
        let completion = AgentPaneShellCompletion(shell: "/bin/bash", timeout: Self.timeout)
        #expect(values(try await completion.complete("ech", cwd: cwd)).contains("echo"))
        let files = try await completion.complete("cat al", cwd: cwd)
        #expect(files.start == 4)
        #expect(Set(values(files)) == ["alpha.txt", "alps/"])
    }

    @Test func aMissingFolderFails() async throws {
        let completion = AgentPaneShellCompletion(shell: "/bin/zsh", timeout: Self.timeout)
        await #expect(throws: AgentPaneShellCompletion.Failure.folderMissing) {
            try await completion.complete("ech", cwd: "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func requestsDecodeOnlyWithALineAndAnAbsoluteFolder() {
        func request(_ params: [String: Any]) -> AgentPaneRequest {
            AgentPaneRequest(body: ["method": "shell.complete", "params": params] as [String: Any])
        }
        #expect(request(["line": "git ch", "cwd": "/repo"]) == .shellComplete(line: "git ch", cwd: "/repo"))
        #expect(request(["line": "git ch", "cwd": "repo"]) == .shellComplete(line: "git ch", cwd: nil))
        // An empty line completes commands.
        #expect(request(["line": ""]) == .shellComplete(line: "", cwd: nil))
        #expect(request([:]) == .unsupported("shell.complete"))
        #expect(request(["line": "x"]).isShell)
    }

    /// Completion functions run code (zsh's `_git` runs git), so page script cannot start one.
    @Test func aCompletionRunsOnlyAfterAGestureInThePane() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.shell.completion = AgentPaneShellCompletion(shell: "/bin/zsh", timeout: Self.timeout)
        let cwd = try folder(["alpha.txt"])
        let refused = await model.respond(to: .shellComplete(line: "cat al", cwd: cwd))
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "shell.gesture_required")
        model.transport.gestures.record()
        let answered = await model.respond(to: .shellComplete(line: "cat al", cwd: cwd))
        let value = try #require(answered["value"] as? [String: Any])
        #expect(value["start"] as? Int == 4)
        let candidates = try #require(value["candidates"] as? [[String: Any]])
        #expect(candidates.compactMap { $0["value"] as? String } == ["alpha.txt"])
    }

    /// cx-6so.47: a completion that passes the deadline answers as a timeout, never as "Could
    /// not start" (the shell did start). The fake `bash` sleeps past a short deadline.
    @Test func aCompletionPastTheDeadlineAnswersATimeout() async throws {
        let bin = try folder()
        let bash = bin + "/bash"
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: URL(fileURLWithPath: bash))
        #expect(chmod(bash, 0o755) == 0)
        let completion = AgentPaneShellCompletion(shell: bash, timeout: .milliseconds(300))
        await #expect(throws: AgentPaneShellCompletion.Failure.timedOut) {
            try await completion.complete("ech", cwd: bin)
        }
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.shell.completion = completion
        model.transport.gestures.record()
        let answered = await model.respond(to: .shellComplete(line: "ech", cwd: bin))
        let error = try #require(answered["error"] as? [String: Any])
        #expect(error["code"] as? String == "shell.timed_out")
        #expect(error["message"] as? String != AgentPaneModel.shellFailureMessage(AgentPaneShell.Failure.spawnFailed(0)))
    }
}
