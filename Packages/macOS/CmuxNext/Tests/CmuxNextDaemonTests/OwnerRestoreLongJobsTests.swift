import CmuxNextCompat
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The incident of 2026-11-02 (plans/cmux-next/long-jobs-DESIGN.md): the session owner ran a 303 s
/// output cleanup while it restored. `server ensure --restore-progress` was capped at 150 s whatever its
/// progress said, and the next connect, to the remembered socket the owner parked, timed out its
/// `identify` and read as a plain failure. These run the real launcher and connection against a stand-in
/// `cmux-tui` script and a real listening socket that never answers.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OwnerRestoreLongJobsTests {
    private let directory = URL(fileURLWithPath: "/tmp/cnlj-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)

    private static func progressLine(done: Int, total: Int = 900) -> String {
        #"{"progress":"restoring","session":"cmux-app","pid":4242,"waited_ms":1000,"jobs":[{"id":"output_cleanup:1","kind":"registry.output_cleanup","title":"Cleaning up stored terminal output","detail":"segment \#(done) of \#(total)","done":\#(done),"total":\#(total),"unit":"segments","started_ms":1793683713000,"updated_ms":\#(1_793_683_713_000 + done),"blocks":["startup","quit"],"cancellable":false}]}"#
    }

    /// A stand-in `cmux-tui`: no owner for `server status`; `server ensure` echoes each line the test
    /// writes into `control` (the owner's restore progress) and prints the result on `done`.
    private func standIn(control: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case " $* " in
        *" server status "*) exit 1 ;;
        *" server ensure "*)
            exec 3<'\(control.path)'
            while IFS= read -r line <&3; do
                if [ "$line" = done ]; then
                    echo '{"status":"started","session":"cmux-app","socket":"\(directory.path)/owner.sock","pid":4242,"generation":"g-1"}'
                    exit 0
                fi
                printf '%s\\n' "$line"
            done
            exit 3 ;;
        esac
        exit 64
        """
        let binary = directory.appendingPathComponent("cmux-tui")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        guard mkfifo(control.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        return binary
    }

    @Test func ensureKeepsWaitingPastTheOldCapWhileTheOwnersJobsProgress() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("control")
        let binary = try standIn(control: control)
        let clock = ManualClock()
        let launcher = DaemonLauncher(configuration: .init(binary: binary, session: "cmux-app", binaryIsBundled: true),
                                      environment: { ["PATH": "/usr/bin:/bin"] }, ensureTimeout: .seconds(20), clock: clock)
        let (reports, reported) = AsyncStream.makeStream(of: OwnerRestoreProgress.Report.self)
        launcher.restoreProgress.observe { reported.yield($0) }
        var received = reports.makeAsyncIterator()
        // task-owner: awaited below; cancelled by the test's end otherwise.
        let ensure = Task { try await launcher.ensure() }
        defer { ensure.cancel() }
        // Opens the control pipe for writing once the stand-in opened it for reading (off the test's task: open blocks).
        let writer = try await Task.detached { () throws -> FileHandle in
            let fd = open(control.path, O_WRONLY)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }.value
        // 10 idle windows of 20 s = 200 s, past the old 150 s cap, each with one progress line.
        // The watchdog sleeps (and took its baseline) before each line, so each window sees exactly one line.
        for step in 1...10 {
            try await clock.waitForSleeper()
            try writer.write(contentsOf: Data((Self.progressLine(done: step * 90) + "\n").utf8))
            let report = try #require(await received.next())
            #expect(report.pid == 4242)
            #expect(report.jobs.map(\.kind) == ["registry.output_cleanup"])
            #expect(report.jobs.first?.done == UInt64(step * 90))
            clock.advance(by: .seconds(20))
        }
        #expect(clock.now.offset == .seconds(200))
        try writer.write(contentsOf: Data("done\n".utf8))
        let result = try await ensure.value
        #expect(result.pid == 4242)
        #expect(launcher.restoreProgress.current?.jobs.first?.percent == 99)
    }

    @Test func ensureStillGivesUpWhenTheOwnerStopsReporting() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = directory.appendingPathComponent("control")
        let binary = try standIn(control: control)
        let clock = ManualClock()
        let launcher = DaemonLauncher(configuration: .init(binary: binary, session: "cmux-app", binaryIsBundled: true),
                                      environment: { ["PATH": "/usr/bin:/bin"] }, ensureTimeout: .seconds(20), clock: clock)
        // task-owner: awaited below.
        let ensure = Task { try await launcher.ensure() }
        defer { ensure.cancel() }
        let writer = try await Task.detached { () throws -> FileHandle in
            let fd = open(control.path, O_WRONLY)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }.value
        _ = writer
        // No line for a whole idle window: a stalled owner still ends the wait.
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(20))
        await #expect(throws: DaemonError.self) { try await ensure.value }
    }

    /// cmux-tui's `session_storage_component("cmux-app")`, computed from the Rust algorithm
    /// (FNV-1a 64 over the name), so the app reads the status file where the owner writes it.
    @Test func statusFileLivesInTheOwnersSessionDirectory() {
        #expect(OwnerJobsFile.storageComponent(session: "cmux-app") == "cmux-app-b8bbe2ca34de19a2")
        #expect(OwnerJobsFile.storageComponent(session: "cmux-app-nightly") == "cmux-app-nightly-1d6bc9a9bb32a162")
    }

    /// A listening socket that never accepts: the kernel completes connects into its backlog and
    /// nothing ever reads them, as the owner parked every connection during the cleanup.
    private func parkedSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() where index < buffer.count - 1 { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    private static func nowMs() -> Int64 { Int64(exactly: (Date().timeIntervalSince1970 * 1000).rounded()) ?? 0 }

    /// The owner's status file, written by a live process (this one), last changed at `updatedMs`, its job blocking
    /// `blocks` (only a `startup` job is start progress).
    private static func writeStatus(in sessionDirectory: URL, updatedMs: Int64, blocks: String = #""startup""#,
                                    version: Int = 1) throws {
        let status = #"{"version":\#(version),"pid":\#(getpid()),"updated_ms":\#(updatedMs),"jobs":[{"id":"output_cleanup:1","kind":"registry.output_cleanup","title":"Cleaning up stored terminal output","detail":"segment 387 of 900","done":387,"total":900,"unit":"segments","started_ms":\#(updatedMs - 60_000),"updated_ms":\#(updatedMs),"blocks":[\#(blocks)],"cancellable":false}]}"#
        try Data(status.utf8).write(to: sessionDirectory.appendingPathComponent(OwnerJobsFile.fileName))
    }

    @Test func aParkedIdentifyOnTheLiveOwnersRememberedSocketIsRestoringNotAFailure() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("o.sock").path
        let listener = try parkedSocket(at: socketPath)
        defer { close(listener) }
        // The owner's status file, written by a live process (this one).
        let state = directory.appendingPathComponent("state", isDirectory: true)
        let session = "cmux-app"
        let sessionDirectory = state.appendingPathComponent(OwnerJobsFile.storageComponent(session: session), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Self.writeStatus(in: sessionDirectory, updatedMs: Self.nowMs())

        let launcher = DaemonLauncher(configuration: .init(binary: URL(fileURLWithPath: "/usr/bin/false"), session: session,
                                                           stateDirectory: state, rememberedSocket: socketPath, binaryIsBundled: true),
                                      environment: { [:] })
        let base = DaemonConnection.Configuration(requiredCapabilities: [], requestTimeout: .milliseconds(500), terminalEnvironment: nil)
        let connection = DaemonConnection(configuration: launcher.localOwnerHooks(base), endpointProvider: launcher.endpointProvider)
        defer { Task { await connection.close() } }
        var failure: DaemonError?
        do {
            _ = try await connection.start()
        } catch let error as DaemonError {
            failure = error
        }
        let error = try #require(failure, "the parked owner answered")
        guard case .ownerRestoring = error else {
            Issue.record("a parked identify on a live owner read as \(error), not restoring")
            return
        }
        #expect(DaemonStartup.shared.ownerIsRestoring(error))
        #expect(!DaemonStartupState.connecting.showsFailure(error, retries: true))
        let jobs = try #require(launcher.restoreProgress.current?.jobs)
        #expect(jobs.map(\.kind) == ["registry.output_cleanup"])
        #expect(jobs.first?.percent == 43)
    }

    enum NoProgress: CaseIterable, Sendable {
        /// No status file (an owner that names no job).
        case noFile
        /// Its startup job stopped changing past the stall bound (a wedged owner whose process lives on).
        case stale
        /// Only a background job beats (cmux-tui's stall bound counts startup jobs only).
        case backgroundOnly
        /// A file of another format version.
        case otherVersion
    }

    /// Without live start progress the parked identify stays a failure, so Retry Now and Restart show.
    @Test(arguments: NoProgress.allCases)
    func aParkedIdentifyWithoutLiveProgressStaysAFailure(_ file: NoProgress) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("o.sock").path
        let listener = try parkedSocket(at: socketPath)
        defer { close(listener) }
        let state = directory.appendingPathComponent("state", isDirectory: true)
        let sessionDirectory = state.appendingPathComponent(OwnerJobsFile.storageComponent(session: "cmux-app"), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        switch file {
        case .noFile: break
        case .stale: try Self.writeStatus(in: sessionDirectory, updatedMs: Self.nowMs() - 600_000)
        case .backgroundOnly: try Self.writeStatus(in: sessionDirectory, updatedMs: Self.nowMs(), blocks: #""none""#)
        case .otherVersion: try Self.writeStatus(in: sessionDirectory, updatedMs: Self.nowMs(), version: 2)
        }
        let launcher = DaemonLauncher(configuration: .init(binary: URL(fileURLWithPath: "/usr/bin/false"), session: "cmux-app",
                                                           stateDirectory: state, binaryIsBundled: true),
                                      environment: { [:] })
        let base = DaemonConnection.Configuration(requiredCapabilities: [], requestTimeout: .milliseconds(300), terminalEnvironment: nil)
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: socketPath), configuration: launcher.localOwnerHooks(base))
        defer { Task { await connection.close() } }
        var failure: DaemonError?
        do {
            _ = try await connection.start()
        } catch let error as DaemonError {
            failure = error
        }
        let error = try #require(failure)
        guard case .timedOut = error else {
            Issue.record("a parked identify with no live progress read as \(error), not a timeout")
            return
        }
        #expect(launcher.restoreProgress.current == nil)
    }
}
