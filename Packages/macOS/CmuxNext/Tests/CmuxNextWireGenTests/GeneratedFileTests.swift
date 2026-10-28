import Foundation
import Testing
@testable import CmuxNextWireGen

/// GeneratedFile, the one write path of CmuxNextWireGen: the whole file appears at once, and the write
/// stays in the output directory.
///
/// Why the directory matters: SwiftPM runs a build-tool command in a sandbox. In a sandboxed process,
/// Foundation's `Data.write(to:options: .atomic)` asks FileManager for an item-replacement directory
/// (swift-foundation Data+Writing.swift, createProtectedTemporaryFile), and that look-up calls
/// coreservicesd. In a fleet step (a non-GUI session) the look-up blocked forever: swift-build waited
/// 95 minutes on two CmuxNextWireGen processes at 0 % CPU (handoff wiregen-hang.md, 2026-10-28).
/// The sandboxed test runs the built tool in a sandbox that refuses every write outside its output
/// directory, so a write that goes through the replacement directory fails (or hangs, and the test
/// stops it) instead of passing. It does not reproduce the coreservicesd hang itself; that needs a
/// non-GUI session.
@Suite struct GeneratedFileTests {
    private static func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "GeneratedFileTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fixturesDirectory() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appending(path: "cmux-tui/spec/fixtures/ipc-method-tables", directoryHint: .isDirectory)
    }

    /// The real path of `url`, `/private/var/...` for `/var/...`: a sandbox profile matches real paths.
    private static func realPath(_ url: URL) throws -> String {
        guard let resolved = unsafe realpath(url.path(percentEncoded: false), nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { unsafe free(resolved) }
        return unsafe String(cString: resolved)
    }

    /// The CmuxNextWireGen executable of this build: the plugin's host tool (`CmuxNextWireGen-tool`)
    /// or the product, in a directory above this test bundle's image.
    private static func toolExecutable() throws -> URL {
        var info = Dl_info()
        guard unsafe dladdr(#dsohandle, &info) != 0, let name = unsafe info.dli_fname else {
            throw CocoaError(.fileNoSuchFile)
        }
        var directory = URL(fileURLWithPath: unsafe String(cString: name)).deletingLastPathComponent()
        while directory.path(percentEncoded: false) != "/" {
            for tool in ["CmuxNextWireGen-tool", "CmuxNextWireGen"] {
                let candidate = directory.appending(path: tool, directoryHint: .notDirectory)
                var isDirectory: ObjCBool = false
                if unsafe FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false),
                                                         isDirectory: &isDirectory),
                    !isDirectory.boolValue,
                    FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false))
                {
                    return candidate
                }
            }
            directory.deleteLastPathComponent()
        }
        Issue.record("no CmuxNextWireGen executable above \(unsafe String(cString: name))")
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func writesTheBytesAndLeavesNoOtherFile() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "Out.swift", directoryHint: .notDirectory)

        try GeneratedFile(url: output).write("let a = 1\n")
        #expect(try Data(contentsOf: output) == Data("let a = 1\n".utf8))
        try GeneratedFile(url: output).write("let b = 22\n")
        #expect(try Data(contentsOf: output) == Data("let b = 22\n".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["Out.swift"])
    }

    @Test func refusesAMissingDirectoryWithItsPath() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "missing/Out.swift", directoryHint: .notDirectory)

        let error = #expect(throws: WireGenError.self) {
            try GeneratedFile(url: output).write("let a = 1\n")
        }
        guard case .unwritable(let path, _) = error else {
            Issue.record("expected unwritable, got \(String(describing: error))")
            return
        }
        #expect(path == output.path(percentEncoded: false))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == [])
    }

    /// The built tool in a sandbox that refuses writes outside its output directory and the
    /// coreservicesd look-up: it writes the fixture's DaemonWireEvent there, the same bytes as
    /// EventEmitter in this process, and nothing else. Foundation's atomic write fails here (it
    /// writes in the item-replacement directory first).
    @Test func writesOnlyInTheOutputDirectoryInASandbox() async throws {
        let tool = try Self.toolExecutable()
        let output = try Self.scratchDirectory()
        let logs = try Self.scratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: logs)
        }
        let fixtures = Self.fixturesDirectory()
        let sdkSchema = fixtures.appending(path: "sdk-schema.json", directoryHint: .notDirectory)
        let resourceOperations = fixtures.appending(path: "resource-operations-v2.json", directoryHint: .notDirectory)
        let events = output.appending(path: "DaemonWireEvent+Fixture.swift", directoryHint: .notDirectory)
        let profile = """
            (version 1)
            (allow default)
            (deny mach-lookup (global-name "com.apple.CoreServices.coreservicesd"))
            (deny file-write*)
            (allow file-write* (subpath "\(try Self.realPath(output))") (subpath "/dev"))
            """
        let stderrFile = logs.appending(path: "stderr.txt", directoryHint: .notDirectory)
        FileManager.default.createFile(atPath: stderrFile.path(percentEncoded: false), contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrFile)
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p", profile, tool.path(percentEncoded: false),
            "--sdk-schema", sdkSchema.path(percentEncoded: false),
            "--resource-operations", resourceOperations.path(percentEncoded: false),
            "--event-output", events.path(percentEncoded: false),
            "--event-import", "CmuxNextIPC",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle
        try process.run()
        // The hang this guards against never ends by itself: stop the tool after 60 s.
        let deadline = ContinuousClock.now + .seconds(60)
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let hung = process.isRunning
        if hung {
            process.terminate()
            while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        }
        let stderrText = String(decoding: try Data(contentsOf: stderrFile), as: UTF8.self)

        #expect(!hung, "CmuxNextWireGen did not end in 60 s in the sandbox; stderr: \(stderrText)")
        #expect(process.terminationStatus == 0, "exit \(process.terminationStatus); stderr: \(stderrText)")
        let expected = try EventEmitter(sdkSchema: Data(contentsOf: sdkSchema),
                                        resourceOperations: Data(contentsOf: resourceOperations))
            .source(importing: "CmuxNextIPC")
        #expect((try? Data(contentsOf: events)) == Data(expected.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))
            == ["DaemonWireEvent+Fixture.swift"])
    }
}
