import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("GUI shell session")
struct GuiShellSessionTests {
    @Test func directoryAndEnvironmentPersistAcrossCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("Project One")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = GuiShellSession(workingDirectory: root.path, environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        let first = try await shell.execute(command: "cd 'Project One' && export GUI_CHECK=kept && pwd", requestID: "first")
        #expect(first.exitCode == 0)
        #expect(URL(fileURLWithPath: first.workingDirectory).resolvingSymlinksInPath().path == child.resolvingSymlinksInPath().path)
        let next = try await shell.execute(command: "printf '%s' $GUI_CHECK; pwd", requestID: "next")
        #expect(next.output.contains("kept"))
        #expect(URL(fileURLWithPath: next.workingDirectory).resolvingSymlinksInPath().path == child.resolvingSymlinksInPath().path)
        let back = try await shell.execute(command: "cd - && pwd", requestID: "back")
        #expect(URL(fileURLWithPath: back.workingDirectory).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        let failed = try await shell.execute(command: "cd no-such-directory", requestID: "failed")
        #expect(failed.exitCode != 0)
        #expect(URL(fileURLWithPath: failed.workingDirectory).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        await shell.close()
    }

    @Test func duplicateRequestDoesNotRunTwiceAndOutputIsBounded() async throws {
        let shell = GuiShellSession(workingDirectory: "/tmp", environment: ["PATH": "/usr/bin:/bin"], outputLimit: 1024)
        let command = "export GUI_COUNT=$(( ${GUI_COUNT:-0} + 1 )); printf '%s' $GUI_COUNT"
        let first = try await shell.execute(command: command, requestID: "once")
        let retry = try await shell.execute(command: command, requestID: "once")
        #expect(first == retry)
        let count = try await shell.execute(command: "printf '%s' $GUI_COUNT", requestID: "count")
        #expect(count.output == "1")
        let large = try await shell.execute(command: "printf '%10000s' x", requestID: "large")
        #expect(large.output.utf8.count <= 1024)
        #expect(large.output.hasSuffix("x"))
        await shell.close()
    }

    @Test func timeoutAndExitAllowANewCommand() async throws {
        let shell = GuiShellSession(workingDirectory: "/tmp", environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(2))
        await #expect(throws: GuiShellError.self) { try await shell.execute(command: "sleep 30", requestID: "timeout") }
        let next = try await shell.execute(command: "pwd", requestID: "recovered")
        #expect(next.exitCode == 0)
        await #expect(throws: GuiShellError.self) { try await shell.execute(command: "exit", requestID: "exit") }
        let recovered = try await shell.execute(command: "pwd", requestID: "recovered-again")
        #expect(recovered.exitCode == 0)
        await shell.close()
    }
}
