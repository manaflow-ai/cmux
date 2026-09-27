import CMUXAgentLaunch
import Foundation
import Testing

@Suite("AgentMove path mapping")
struct AgentMovePathMapTests {
    @Test func sharedHomeKeepsEveryPath() {
        let map = AgentMovePathMap(sourceHome: "/Users/a", destinationHome: "/home/a", sharesHomePath: true)
        #expect(!map.rewritesPaths)
        #expect(map.destinationPath(for: "/Users/a/src/x") == "/Users/a/src/x")
    }

    @Test func differentHomeMapsOnlyTheHomePrefix() {
        let map = AgentMovePathMap(sourceHome: "/Users/a/", destinationHome: "/home/a", sharesHomePath: false)
        #expect(map.rewritesPaths)
        #expect(map.destinationPath(for: "/Users/a/src/x") == "/home/a/src/x")
        #expect(map.destinationPath(for: "/Users/a") == "/home/a")
        #expect(map.destinationPath(for: "/Users/ab/x") == "/Users/ab/x")
        #expect(map.destinationPath(for: "/opt/x") == "/opt/x")
    }

    @Test func sameHomeStringIsNotARewrite() {
        let map = AgentMovePathMap(sourceHome: "/Users/a", destinationHome: "/Users/a", sharesHomePath: false)
        #expect(!map.rewritesPaths)
    }

    @Test func claudeSlugReplacesEveryNonAlphanumeric() {
        #expect(ClaudeProjectSlug().slug(forWorkingDirectory: "/Users/a/my_proj.v2") == "-Users-a-my-proj-v2")
        #expect(ClaudeProjectSlug().slug(forWorkingDirectory: "/home/é") == "-home--")
    }

    @Test func sshInvocationSendsScriptOnStdin() {
        let target = AgentMoveSSHTarget(destination: "dev@box", port: "2222", identityFile: "/k", options: ["StrictHostKeyChecking=no"])
        let invocation = AgentMoveEndpoint.ssh(target).shellInvocation("echo 'hi'")
        #expect(invocation.arguments == [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=30", "-p", "2222", "-i", "/k",
            "-o", "StrictHostKeyChecking=no", "dev@box", "sh -s",
        ])
        #expect(invocation.standardInput == "{\necho 'hi'\n} </dev/null\n")
        #expect(AgentMoveEndpoint.ssh(target).transferPath("/x") == "dev@box:/x")
        #expect(target.isTransportSafe)
        #expect(!AgentMoveSSHTarget(destination: "ssh://box").isTransportSafe)
        #expect(!AgentMoveSSHTarget(destination: "box", options: ["ProxyCommand=a b"]).isTransportSafe)
    }
}

/// Runs commands for real, mapping the SSH host `fakehost` onto a local
/// directory tree whose `$HOME` is `remoteHome`.
private struct LoopbackRunner: AgentMoveCommandRunning {
    static let host = "fakehost"
    let remoteHome: String

    func run(_ invocation: AgentMoveInvocation) throws -> AgentMoveCommandResult {
        var arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, new in new }
        if arguments.first == "ssh" {
            #expect(arguments[arguments.count - 2] == Self.host)
            #expect(arguments.last == "sh -s")
            arguments = ["/bin/sh", "-s"]
            environment["HOME"] = remoteHome
        } else {
            environment.removeValue(forKey: "GIT_SSH_COMMAND")
            var rewritten: [String] = []
            var index = 0
            while index < arguments.count {
                if arguments[index] == "-e", arguments.first?.hasSuffix("rsync") == true {
                    index += 2
                    continue
                }
                let argument = arguments[index]
                rewritten.append(argument.hasPrefix(Self.host + ":") ? String(argument.dropFirst(Self.host.count + 1)) : argument)
                index += 1
            }
            arguments = rewritten
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data((invocation.standardInput ?? "").utf8))
        try input.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return AgentMoveCommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }
}

private final class MoveFixture {
    let root: String
    let localHome: String
    let remoteHome: String
    let sessionID = "0b7a1e7c-3f0a-4c6e-9d59-8a0d8f7c2b11"
    let remote = AgentMoveEndpoint.ssh(AgentMoveSSHTarget(destination: LoopbackRunner.host))

    init(remoteHomeIsAliasOfLocal: Bool = false) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = String(cString: realpath(base.path, nil))
        localHome = root + "/local"
        remoteHome = root + "/remote"
        try FileManager.default.createDirectory(atPath: localHome, withIntermediateDirectories: true)
        if remoteHomeIsAliasOfLocal {
            try FileManager.default.createSymbolicLink(atPath: remoteHome, withDestinationPath: localHome)
        } else {
            try FileManager.default.createDirectory(atPath: remoteHome, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    var runner: LoopbackRunner { LoopbackRunner(remoteHome: remoteHome) }

    @discardableResult
    func sh(_ script: String, home: String? = nil) throws -> String {
        let result = try LoopbackRunner(remoteHome: home ?? localHome)
            .run(AgentMoveInvocation(arguments: ["/bin/sh", "-c", "set -e\n" + script], environment: ["HOME": home ?? localHome]))
        #expect(result.succeeded, "\(script): \(result.standardError)")
        return result.trimmedOutput
    }

    func write(_ path: String, _ contents: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    func projectDirectory(home: String, cwd: String) -> String {
        home + "/.claude/projects/" + ClaudeProjectSlug().slug(forWorkingDirectory: cwd)
    }

    /// A repo at local `proj` on branch `feature`, cloned to the remote home.
    func makeRepositories() throws {
        try sh("""
        git init -q -b main \(localHome)/proj
        cd \(localHome)/proj
        git config user.email t@t; git config user.name t
        printf 'one\\n' > a.txt; printf 'gone\\n' > b.txt; printf 'build/\\n' > .gitignore
        git add -A; git commit -qm init
        git checkout -qb feature
        git clone -q \(localHome)/proj \(remoteHome)/proj
        """)
    }

    func writeSession(cwd: String) throws {
        let project = projectDirectory(home: localHome, cwd: cwd)
        try write(project + "/\(sessionID).jsonl", "{\"type\":\"user\",\"cwd\":\"\(cwd)\"}\n")
        try write(project + "/\(sessionID)/subagents/a.jsonl", "sub\n")
        try write(localHome + "/.claude/file-history/\(sessionID)/f@v1", "hist\n")
        try write(project + "/memory/local.md", "local memory\n")
    }

    func move(to destination: AgentMoveEndpoint, from source: AgentMoveEndpoint, carriesCode: Bool = true) throws -> AgentMoveOutcome {
        try AgentSessionMover(runner: runner).move(AgentMoveRequest(
            sessionID: sessionID,
            source: source,
            destination: destination,
            localHome: localHome,
            carriesCode: carriesCode
        ))
    }
}

@Suite("AgentSessionMover", .serialized)
struct AgentSessionMoverTests {
    @Test func movesCodeAndSessionDataThereAndBack() throws {
        let f = try MoveFixture()
        try f.makeRepositories()
        let cwd = f.localHome + "/proj"
        try f.sh("cd \(cwd); printf 'two\\n' > a.txt; rm b.txt; printf 'new\\n' > c.txt; mkdir build; printf x > build/o")
        try f.writeSession(cwd: cwd)
        let remoteProject = f.projectDirectory(home: f.remoteHome, cwd: f.remoteHome + "/proj")
        try f.write(remoteProject + "/memory/remote.md", "remote memory\n")

        let outcome = try f.move(to: f.remote, from: .local)
        #expect(outcome.destinationWorkingDirectory == f.remoteHome + "/proj")
        #expect(outcome.pathMap.rewritesPaths)
        guard case .synced(_, _, let branch, _, let addedWorktree) = outcome.code else {
            Issue.record("code not synced: \(outcome.code)")
            return
        }
        #expect(branch == "feature")
        #expect(!addedWorktree)

        let remoteCwd = f.remoteHome + "/proj"
        #expect(f.read(remoteCwd + "/a.txt") == "two\n")
        #expect(f.read(remoteCwd + "/c.txt") == "new\n")
        #expect(!FileManager.default.fileExists(atPath: remoteCwd + "/b.txt"))
        #expect(!FileManager.default.fileExists(atPath: remoteCwd + "/build"))
        #expect(try f.sh("git -C \(remoteCwd) symbolic-ref --short HEAD") == "feature")
        #expect(try f.sh("git -C \(remoteCwd) rev-parse HEAD") == f.sh("git -C \(cwd) rev-parse HEAD"))
        #expect(f.read(remoteProject + "/\(f.sessionID).jsonl") != nil)
        #expect(f.read(remoteProject + "/\(f.sessionID)/subagents/a.jsonl") == "sub\n")
        #expect(f.read(f.remoteHome + "/.claude/file-history/\(f.sessionID)/f@v1") == "hist\n")
        #expect(f.read(remoteProject + "/memory/local.md") == "local memory\n")
        let localProject = f.projectDirectory(home: f.localHome, cwd: cwd)
        #expect(f.read(localProject + "/memory/remote.md") == "remote memory\n")

        // Continue on the remote, then move back.
        try f.sh("printf 'three\\n' > \(remoteCwd)/a.txt; printf '{\"type\":\"assistant\"}\\n' >> \(remoteProject)/\(f.sessionID).jsonl")
        let back = try f.move(to: .local, from: f.remote)
        #expect(back.destinationWorkingDirectory == cwd)
        #expect(back.sourceWorkingDirectory == remoteCwd)
        #expect(f.read(cwd + "/a.txt") == "three\n")
        #expect(f.read(cwd + "/c.txt") == "new\n")
        #expect(f.read(localProject + "/\(f.sessionID).jsonl")?.contains("assistant") == true)
        #expect(FileManager.default.fileExists(atPath: cwd + "/build/o"))
    }

    @Test func sameHomeDirectoryKeepsSlugAndPaths() throws {
        // The remote $HOME is a different path to the same directory, as with a bind mount.
        let f = try MoveFixture(remoteHomeIsAliasOfLocal: true)
        let cwd = f.localHome + "/plain"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try f.writeSession(cwd: cwd)
        let outcome = try f.move(to: f.remote, from: .local)
        #expect(outcome.pathMap.sharesHomePath)
        #expect(!outcome.pathMap.rewritesPaths)
        #expect(outcome.destinationWorkingDirectory == cwd)
        #expect(outcome.destinationTranscriptPath == f.projectDirectory(home: f.localHome, cwd: cwd) + "/\(f.sessionID).jsonl")
    }

    @Test func refusesWhileSessionIsLive() throws {
        let f = try MoveFixture()
        let cwd = f.localHome + "/plain"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try f.writeSession(cwd: cwd)
        try f.write(f.localHome + "/.claude/sessions/\(getpid()).json", "{\"sessionId\":\"\(f.sessionID)\"}")
        #expect(throws: AgentMoveError.liveOnSource(host: "local")) { try f.move(to: f.remote, from: .local) }
    }

    @Test func nonGitCwdMovesOnlySessionData() throws {
        let f = try MoveFixture()
        let cwd = f.localHome + "/plain"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: f.remoteHome + "/plain", withIntermediateDirectories: true)
        try f.writeSession(cwd: cwd)
        let outcome = try f.move(to: f.remote, from: .local)
        #expect(outcome.code == .notGitCheckout(path: cwd))
        #expect(FileManager.default.fileExists(atPath: outcome.destinationTranscriptPath))
    }

    @Test func refusesMissingDestinationCwd() throws {
        let f = try MoveFixture()
        let cwd = f.localHome + "/plain"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try f.writeSession(cwd: cwd)
        #expect(throws: AgentMoveError.destinationWorkingDirectoryMissing(f.remoteHome + "/plain")) {
            try f.move(to: f.remote, from: .local)
        }
    }

    @Test func refusesDirtyDestinationCheckout() throws {
        let f = try MoveFixture()
        try f.makeRepositories()
        try f.writeSession(cwd: f.localHome + "/proj")
        try f.sh("printf 'theirs\\n' > \(f.remoteHome)/proj/a.txt")
        #expect(throws: AgentMoveError.destinationCheckoutDirty(path: f.remoteHome + "/proj")) {
            try f.move(to: f.remote, from: .local)
        }
        #expect(!FileManager.default.fileExists(atPath: f.projectDirectory(home: f.remoteHome, cwd: f.remoteHome + "/proj")))
    }

    @Test func refusesDivergedDestinationBranch() throws {
        let f = try MoveFixture()
        try f.makeRepositories()
        try f.writeSession(cwd: f.localHome + "/proj")
        try f.sh("""
        cd \(f.remoteHome)/proj
        git config user.email t@t; git config user.name t
        printf 'r\\n' > r.txt; git add r.txt; git commit -qm remote; git checkout -q --detach
        """)
        #expect(throws: AgentMoveError.destinationBranchDiverged(branch: "feature")) {
            try f.move(to: f.remote, from: .local)
        }
        // A refused move does not mark the source tree as carried.
        #expect(try f.sh("git -C \(f.localHome)/proj rev-parse -q --verify refs/agent-move/\(f.sessionID) || echo none") == "none")
    }

    @Test func folderInsideAnotherRepositoryIsNotTheCheckout() throws {
        let f = try MoveFixture()
        try f.makeRepositories()
        try f.writeSession(cwd: f.localHome + "/proj")
        // The remote home is itself a repository that ignores everything, and
        // `proj` there is a plain folder inside it.
        try f.sh("""
        rm -rf \(f.remoteHome)/proj; mkdir -p \(f.remoteHome)/proj
        cd \(f.remoteHome); git init -q -b main; printf '*\\n' > .gitignore
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m home
        """)
        let homeHead = try f.sh("git -C \(f.remoteHome) rev-parse HEAD")
        #expect(throws: AgentMoveError.destinationRepositoryMissing(
            checkout: f.remoteHome + "/proj",
            repository: f.remoteHome + "/proj/.git"
        )) {
            try f.move(to: f.remote, from: .local)
        }
        #expect(try f.sh("git -C \(f.remoteHome) rev-parse HEAD") == homeHead)
        #expect(try f.sh("git -C \(f.remoteHome) symbolic-ref --short HEAD") == "main")
    }

    @Test func addsWorktreeWhenRepositoryExistsButPathDoesNot() throws {
        let f = try MoveFixture()
        try f.makeRepositories()
        let cwd = f.localHome + "/proj-wt"
        try f.sh("git -C \(f.localHome)/proj worktree add -q -b wt \(cwd); printf 'wt\\n' > \(cwd)/w.txt")
        try f.writeSession(cwd: cwd)
        var events: [AgentMoveProgress] = []
        let outcome = try AgentSessionMover(runner: f.runner, progress: { events.append($0) }).move(AgentMoveRequest(
            sessionID: f.sessionID, source: .local, destination: f.remote, localHome: f.localHome
        ))
        #expect(events == [.addingWorktree(path: f.remoteHome + "/proj-wt")])
        #expect(f.read(f.remoteHome + "/proj-wt/w.txt") == "wt\n")
        #expect(try f.sh("git -C \(f.remoteHome)/proj-wt symbolic-ref --short HEAD") == "wt")
        #expect(outcome.destinationWorkingDirectory == f.remoteHome + "/proj-wt")
    }

    @Test func refusesNewerDestinationTranscript() throws {
        let f = try MoveFixture()
        let cwd = f.localHome + "/plain"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: f.remoteHome + "/plain", withIntermediateDirectories: true)
        try f.writeSession(cwd: cwd)
        let remoteProject = f.projectDirectory(home: f.remoteHome, cwd: f.remoteHome + "/plain")
        try f.write(remoteProject + "/\(f.sessionID).jsonl", "{\"type\":\"user\",\"cwd\":\"\(cwd)\"}\n{\"more\":1}\n")
        #expect(throws: AgentMoveError.destinationTranscriptNewer) { try f.move(to: f.remote, from: .local) }
        try f.write(remoteProject + "/\(f.sessionID).jsonl", "{\"x\":1}\n")
        #expect(throws: AgentMoveError.transcriptsDiverged) { try f.move(to: f.remote, from: .local) }
    }

    @Test func rejectsBadRequests() throws {
        let mover = AgentSessionMover(runner: LoopbackRunner(remoteHome: "/nonexistent"))
        #expect(throws: AgentMoveError.invalidSessionID("nope")) {
            try mover.move(AgentMoveRequest(sessionID: "nope", source: .local, destination: .local, localHome: "/"))
        }
        #expect(throws: AgentMoveError.sameEndpoint) {
            try mover.move(AgentMoveRequest(sessionID: UUID().uuidString, source: .local, destination: .local, localHome: "/"))
        }
    }
}
