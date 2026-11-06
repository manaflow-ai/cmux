import CmuxNextRemote
import Foundation
import Testing

/// The person's own `~/.cmux/bin/cmux` gets a newer build staged beside it, never renamed over a
/// binary a session server runs (cmux-orchestrator-1 ran a 2-week-old build because nothing
/// updated it, and nothing may stop its live session to do so). The stage-only install script runs
/// here against a real file tree: with a `--headless` process running the binary the build waits
/// as `<binary>.staged` and the process keeps running; with none it is swapped in at once.
@Suite(.serialized)
struct RemoteStageScriptTests {
    private struct Tree {
        let root: URL
        let binary: URL
        let plan: RemoteInstallPlan
        let newBuild: Data
    }

    /// A small program built here (a copied system binary is not allowed to run): it sleeps.
    private func compile(_ output: URL) throws {
        let source = output.deletingLastPathComponent().appendingPathComponent("\(output.lastPathComponent).c")
        try "#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-o", output.path, source.path]
        try cc.run()
        cc.waitUntilExit()
        try #require(cc.terminationStatus == 0, "cc could not build the stand-in binary")
    }

    /// The installed binary (a compiled sleeper) and an uploaded new build (a script that answers
    /// `remote-probe`) at the plan's staging path, with a manifest that pins its digest.
    private func tree() throws -> Tree {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rss-\(UUID().uuidString.prefix(8))")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = bin.appendingPathComponent("cmux")
        try compile(binary)
        let newBuild = Data("#!/bin/sh\necho '{\"app\":\"cmux-tui\"}'\n".utf8)
        let scratch = root.appendingPathComponent("new-build")
        try newBuild.write(to: scratch)
        let digest = try SHA256File.hex(of: scratch)
        let commit = String(repeating: "b", count: 40)
        let manifest = try CmuxTUIManifest.decode(Data(#"{"sourceCommit":"\#(commit)","binaries":{"cmux-tui-test":"\#(digest)"}}"#.utf8))
        var plan = try RemoteInstallPlan(commit: commit, artifact: "cmux-tui-test", manifest: manifest, remoteBinary: binary.path)
        plan.stageOnly = true
        try FileManager.default.moveItem(at: scratch, to: URL(fileURLWithPath: plan.stagePath))
        return Tree(root: root, binary: binary, plan: plan, newBuild: newBuild)
    }

    /// Runs `script` with /bin/sh and the remote's system PATH; its stdout and status.
    private func run(_ script: String) throws -> (output: String, status: Int32) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        shell.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        shell.waitUntilExit()
        return (String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), shell.terminationStatus)
    }

    /// The binary started as a session server: argv `<binary> --headless --session main`.
    private func sessionServer(_ binary: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec -a \"$0\" \"$0\" --headless --session main", binary.path]
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !Self.args(of: process.processIdentifier).contains("--headless") { usleep(20_000) } // bounded
        try #require(Self.args(of: process.processIdentifier).contains("--headless"))
        return process
    }

    private static func args(of pid: Int32) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "args=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        ps.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func aRunningSessionServerKeepsItsBinaryAndTheBuildWaitsStaged() throws {
        let tree = try tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let before = try Data(contentsOf: tree.binary)
        let server = try sessionServer(tree.binary)
        defer { if server.isRunning { server.terminate() } }
        let result = try run(tree.plan.uploadScript)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("cmux-install-staged"), "\(result.output)")
        #expect(try Data(contentsOf: tree.binary) == before, "the binary a session server runs was replaced")
        #expect(try Data(contentsOf: URL(fileURLWithPath: tree.binary.path + ".staged")) == tree.newBuild)
        #expect(server.isRunning, "the session server was stopped")
    }

    @Test func withNoSessionServerTheBuildIsSwappedInAndTheOldOneKept() throws {
        let tree = try tree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let before = try Data(contentsOf: tree.binary)
        let result = try run(tree.plan.uploadScript)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("cmux-install-swapped"), "\(result.output)")
        #expect(try Data(contentsOf: tree.binary) == tree.newBuild)
        #expect(try Data(contentsOf: URL(fileURLWithPath: tree.binary.path + ".prev")) == before)
        #expect(!FileManager.default.fileExists(atPath: tree.binary.path + ".staged"))
    }
}
