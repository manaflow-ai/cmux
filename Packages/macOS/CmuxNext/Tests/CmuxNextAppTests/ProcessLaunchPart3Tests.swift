import CmuxNextBrowserCore
import CmuxNextChromiumRuntime
@testable import CmuxNextCompat
@testable import CmuxNextServerHelper
@testable import CmuxNextUpdater
import CmuxNextWakeups
import Foundation
import Testing

/// Task p02-threads-040 (plans/cmux-next/chrome-parity/p02-threads.md, INV-3): the web update unpack, the Chromium
/// runtime's tar, the Mail verification script and the server helper's fixes start their children off the caller
/// (AsyncProcess, or the helper's own utility thread), never on the caller's thread (Chromium's
/// content/browser/child_process_launcher_helper.cc). Each run here comes from the main actor and records no
/// blocking site there.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProcessLaunchPart3Tests {
    @Test func theRuntimeTarListsAndUnpacksFromTheMainActor() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await Self.archive(["hello.txt": "hi"], in: root, gzip: false)
        let unpacker = TarChromiumRuntimeUnpacker()
        let entries = try await Self.fromMain { try await unpacker.entries(of: archive) }
        #expect(entries == ["hello.txt"])
        let out = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await Self.fromMain { try await unpacker.unpack(archive, into: out) }
        #expect(try String(contentsOf: out.appending(path: "hello.txt"), encoding: .utf8) == "hi")
    }

    @Test func theRuntimeTarReportsWhatTarSaidAndAMissingTool() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = root.appending(path: "garbage.tar")
        try Data("not an archive".utf8).write(to: garbage)
        let refused = await #expect(throws: ChromiumRuntimeInstallError.self) {
            _ = try await TarChromiumRuntimeUnpacker().entries(of: garbage)
        }
        if case .unpack(let message)? = refused {
            #expect(!message.isEmpty, "tar's message is the error")
        } else {
            Issue.record("a garbage archive failed with \(String(describing: refused))")
        }
        let missing = await #expect(throws: ChromiumRuntimeInstallError.self) {
            _ = try await TarChromiumRuntimeUnpacker(tool: URL(filePath: "/no/such/tar")).entries(of: garbage)
        }
        if case .unpack? = missing {} else { Issue.record("a missing tar failed with \(String(describing: missing))") }
    }

    @Test func aWebUpdateArchiveUnpacksFromTheMainActorAndGarbageIsRefused() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await Self.archive(["index.html": "<p>web</p>"], in: root, gzip: true)
        let out = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await Self.fromMain { try await WebUpdateStore.unpack(archive, into: out) }
        #expect(try String(contentsOf: out.appending(path: "index.html"), encoding: .utf8) == "<p>web</p>")

        let garbage = root.appending(path: "garbage.tgz")
        try Data("not an archive".utf8).write(to: garbage)
        await #expect(throws: WebUpdateRefusal.integrity("the archive did not unpack")) {
            try await WebUpdateStore.unpack(garbage, into: out)
        }
    }

    @Test func theMailScriptRunnerReturnsOutputAndReportsAFailedScript() async throws {
        let runner = OsascriptRunner()
        let output = try await Self.fromMain { try await runner.run(["-e", "return \"hi\""]) }
        #expect(output == "hi\n")
        do {
            _ = try await runner.run(["-e", "error \"boom\" number 7"])
            Issue.record("a failing script succeeded")
        } catch let failure as VerificationScriptFailure {
            #expect(failure.status != 0)
            #expect(failure.message.contains("boom"))
        }
    }

    @Test func aServerHelperFixRunsOnItsOwnThreadAndReturnsItsOutput() async throws {
        let runner = ProcessFixRunner(limit: .seconds(20))
        let result = try await Self.fromMain { try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo fixed; exit 2"]) }
        #expect(result == FixRunResult(status: 2, output: "fixed\n"))
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(URL(fileURLWithPath: "/no/such/pmset"), [])
        }
    }

    @Test func aServerHelperFixPastItsLimitIsKilled() async {
        let runner = ProcessFixRunner(limit: .milliseconds(200))
        await #expect(throws: ServerHelperTimedOut()) {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"])
        }
    }

    // MARK: Helpers

    static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ProcessLaunchPart3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A tar (gzip when `gzip`) of `files` (name to text), made in `root`.
    static func archive(_ files: [String: String], in root: URL, gzip: Bool) async throws -> URL {
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: source.appending(path: name)) }
        let archive = root.appending(path: gzip ? "pack.tgz" : "pack.tar")
        let made = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/tar"),
                                                               [gzip ? "-czf" : "-cf", archive.path, "-C", source.path] + files.keys.sorted(),
                                                               errorOutput: .merge))
        #expect(made.succeeded, "tar: \(made.text)")
        return archive
    }

    /// Runs `body` from the main actor with a recording table bound, and expects no blocking site on main.
    @MainActor
    static func fromMain<T: Sendable>(_ body: @MainActor () async throws -> T,
                                      sourceLocation: SourceLocation = #_sourceLocation) async throws -> T {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record)
        let value = try await BlockingViolationTable.$scoped.withValue(table) { try await body() }
        await table.flush()
        let onMain = table.sites.filter { $0.context == .main }.map(\.location)
        #expect(onMain.isEmpty, "the start blocked the main thread: \(onMain)", sourceLocation: sourceLocation)
        return value
        #else
        return try await body()
        #endif
    }
}
