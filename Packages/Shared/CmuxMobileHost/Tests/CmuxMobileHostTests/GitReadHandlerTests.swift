import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import Foundation
import Testing

@Suite("Git reads: files policy, scope and reply budget")
struct GitReadHandlerTests {
    /// A home with `src/mono/app` shared; `src/mono` is the repository in
    /// some tests, `src/mono/app` in others.
    struct World {
        let home: URL
        let workspace: URL
        let configuration: MobileFilesConfiguration

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("c13-\(UUID().uuidString)", isDirectory: true)
            home = base.appendingPathComponent("home", isDirectory: true)
            workspace = home.appendingPathComponent("src/mono/app", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("src/mono/lib"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: home.appendingPathComponent("secret.txt"))
            configuration = MobileFilesConfiguration(homeDirectory: home)
        }

        var canonicalWorkspace: String { Self.realpath(workspace.path) }
        var canonicalRepo: String { Self.realpath(workspace.deletingLastPathComponent().path) }

        static func realpath(_ path: String) -> String {
            guard let resolved = Darwin.realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        func git(_ reader: FakeGitReader, configuration git: MobileGitConfiguration = MobileGitConfiguration()) -> MobileChannelHandlers {
            let root = MobileFileRoot(id: "ws_a1", name: "app", url: workspace, writable: true)
            return MobileGit(files: configuration, configuration: git, roots: StaticFileRoots([root]), reader: reader).registering()
        }

        func remove() { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    }

    static let principal = MobileDevicePrincipal(install: "in_phone1", userID: "u1", platform: "ios", appVersion: "1")

    func read(_ handlers: MobileChannelHandlers, _ op: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let handler = try #require(handlers.reads[op])
        return try await handler.read(ReadFrame(id: 1, op: op, params: .object(params)), principal: Self.principal)
    }

    func refusal(_ handlers: MobileChannelHandlers, _ op: String, _ params: [String: JSONValue]) async -> MobileDaemonError? {
        do {
            _ = try await read(handlers, op, params)
            return nil
        } catch let error as MobileDaemonError {
            return error
        } catch {
            return nil
        }
    }

    @Test func aPathOutsideEverySharedFolderIsForbiddenBeforeTheSessionHostRuns() async throws {
        let w = try World()
        defer { w.remove() }
        let reader = FakeGitReader(root: w.home.path)
        let handlers = w.git(reader)
        #expect(await refusal(handlers, "git.status", ["path": .string(w.home.appendingPathComponent("secret.txt").path)])?.code == "git.forbidden")
        #expect(await refusal(handlers, "git.diff", ["path": "/etc", "scope": "uncommitted"])?.code == "git.forbidden")
        #expect(await reader.calls.isEmpty)
    }

    @Test func aRepositoryInsideTheSharedFolderIsReadWhole() async throws {
        let w = try World()
        defer { w.remove() }
        let reader = FakeGitReader(root: w.canonicalWorkspace, files: [GitChangedFile(path: "main.swift", status: .modified, additions: 2)])
        let handlers = w.git(reader)
        let status = try await read(handlers, "git.status", ["path": .string(w.workspace.path)]).decode(as: GitStatusResult.self)
        #expect(status.branch == "main" && status.ahead == 1)
        let diff = try await read(handlers, "git.diff", ["path": .string(w.workspace.path), "scope": "uncommitted",
                                                        "max_patch_bytes": 4_194_304, "max_files": 5000])
            .decode(as: GitDiffResult.self)
        #expect(diff.files.map(\.path) == ["main.swift"])
        let sent = try #require(try await reader.lastDiffParams())
        #expect(sent.paths == nil)
        #expect(sent.path == w.canonicalWorkspace)
        #expect(sent.maxPatchBytes == 128 * 1024 && sent.maxFiles == 1000 && sent.includePatch == false)
    }

    @Test func aRepositoryAboveTheSharedFolderIsRestrictedToItsPrefix() async throws {
        let w = try World()
        defer { w.remove() }
        let reader = FakeGitReader(root: w.canonicalRepo, files: [
            GitChangedFile(path: "app/main.swift", status: .modified, additions: 3, deletions: 1),
            GitChangedFile(path: "lib/other.swift", status: .modified, additions: 5),
            GitChangedFile(path: "app/new.swift", previousPath: "lib/old.swift", status: .renamed),
        ])
        let handlers = w.git(reader)
        let diff = try await read(handlers, "git.diff", ["path": .string(w.workspace.path), "scope": "branch"])
            .decode(as: GitDiffResult.self)
        #expect(try await reader.lastDiffParams()?.paths == ["app"])
        // The fake ignores paths; the host still drops what is outside, renames from outside included.
        #expect(diff.files.map(\.path) == ["app/main.swift"])
        #expect(diff.additions == 3 && diff.deletions == 1 && diff.totalFiles == 1)
        _ = try await read(handlers, "git.diff", ["path": .string(w.workspace.path), "scope": "staged", "paths": ["app/main.swift"]])
        #expect(try await reader.lastDiffParams()?.paths == ["app/main.swift"])
        #expect(await refusal(handlers, "git.diff", ["path": .string(w.workspace.path), "scope": "staged", "paths": ["lib/other.swift"]])?.code
            == "git.forbidden")
    }

    @Test(arguments: ["../secret.txt", "/etc/passwd", "app/./x", "app//x", "app/../lib", "app/.ssh/config", "app/.NPMRC"])
    func escapingOrDeniedPathsAreForbidden(path: String) async throws {
        let w = try World()
        defer { w.remove() }
        let handlers = w.git(FakeGitReader(root: w.canonicalRepo))
        #expect(await refusal(handlers, "git.diff", ["path": .string(w.workspace.path), "scope": "uncommitted", "paths": [.string(path)]])?.code
            == "git.forbidden")
    }

    @Test func filesWithDeniedNamesNeverLeaveTheMac() async throws {
        let w = try World()
        defer { w.remove() }
        let reader = FakeGitReader(root: w.canonicalWorkspace, files: [
            GitChangedFile(path: ".npmrc", status: .modified, additions: 1),
            GitChangedFile(path: "deploy/.ssh/id_ed25519", status: .added, additions: 7),
            GitChangedFile(path: "README.md", status: .modified, additions: 2, deletions: 2),
        ])
        let diff = try await read(w.git(reader), "git.diff", ["path": .string(w.workspace.path), "scope": "uncommitted"])
            .decode(as: GitDiffResult.self)
        #expect(diff.files.map(\.path) == ["README.md"])
        #expect(diff.additions == 2 && diff.deletions == 2 && diff.totalFiles == 1)
    }

    @Test func aLargeReplyDropsTheLargestPatchesThenFiles() async throws {
        let w = try World()
        defer { w.remove() }
        func patch(_ kib: Int) -> String { "@@ -1 +1 @@\n" + String(repeating: "+line of code\n", count: kib * 1024 / 14) }
        let reader = FakeGitReader(root: w.canonicalWorkspace, files: [
            GitChangedFile(path: "a.swift", status: .modified, additions: 1, patch: patch(20)),
            GitChangedFile(path: "b.swift", status: .modified, additions: 1, patch: patch(120)),
            GitChangedFile(path: "c.swift", status: .modified, additions: 1, patch: patch(90)),
        ])
        let budget = MobileGitConfiguration(maxReplyBytes: 150 * 1024)
        let value = try await read(w.git(reader, configuration: budget), "git.diff",
                                   ["path": .string(w.workspace.path), "scope": "uncommitted", "include_patch": true])
        #expect(try JSONEncoder().encode(value).count <= 150 * 1024)
        let diff = try value.decode(as: GitDiffResult.self)
        #expect(diff.files.map(\.path) == ["a.swift", "b.swift", "c.swift"])
        #expect(diff.files[1].patch == nil && diff.files[1].isPatchTruncated)
        #expect(diff.files[0].patch != nil && diff.files[2].patch != nil)

        let tiny = MobileGitConfiguration(maxReplyBytes: 300)
        let many = FakeGitReader(root: w.canonicalWorkspace, files: (0..<20).map {
            GitChangedFile(path: "file\($0).swift", status: .modified, additions: 1)
        })
        let cut = try await read(w.git(many, configuration: tiny), "git.diff", ["path": .string(w.workspace.path), "scope": "uncommitted"])
        #expect(try JSONEncoder().encode(cut).count <= 300)
        let decoded = try cut.decode(as: GitDiffResult.self)
        #expect(decoded.files.count + decoded.filesOmitted == 20)
        #expect(decoded.filesOmitted > 0)
    }

    @Test func sessionHostRefusalsMapToTheGitCodes() async throws {
        let w = try World()
        defer { w.remove() }
        let notRepo = FakeGitReader(root: "", failure: MobileDaemonError(code: "git.not_a_repo", message: "no repo"))
        #expect(await refusal(w.git(notRepo), "git.status", ["path": .string(w.workspace.path)])?.code == "git.not_a_repo")
        let broken = FakeGitReader(root: "", failure: URLError(.timedOut))
        let failed = await refusal(w.git(broken), "git.diff", ["path": .string(w.workspace.path), "scope": "staged"])
        #expect(failed?.code == "git.failed" && failed?.retryable == true)
        #expect(await refusal(w.git(broken), "git.diff", ["path": .string(w.workspace.path), "scope": "everything"])?.code
            == "validation.invalid")
    }

    @Test func gitReadsAreServedOverTheSessionRpcChannel() async throws {
        let w = try World()
        defer { w.remove() }
        let reader = FakeGitReader(root: w.canonicalWorkspace, files: [GitChangedFile(path: "x.swift", status: .added, additions: 4)])
        let h = try await PhoneHarness(handlers: w.git(reader))
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)
        try await rpc.send(frame: .read(ReadFrame(id: 7, op: "git.diff", params: ["path": .string(w.workspace.path), "scope": "uncommitted"])))
        let reply = try await PhoneHarness.nextJSON(rpc)
        #expect(reply["t"] == "read.result")
        #expect(try reply["value"]?.decode(as: GitDiffResult.self).files.first?.path == "x.swift")
        try await rpc.send(frame: .read(ReadFrame(id: 8, op: "git.status", params: ["path": "/private/etc"])))
        let denied = try await PhoneHarness.nextJSON(rpc)
        #expect(denied["code"] == "git.forbidden")
    }
}
