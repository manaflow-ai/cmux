import Darwin
import Foundation
import Testing

@testable import CmuxFoundation

@Suite("CommandRunner descriptor lifecycle", .serialized)
struct CommandRunnerDescriptorLifecycleTests {
    private let tempDirectory = FileManager.default.temporaryDirectory

    @Test("Capture pipes are close-on-exec and close before success returns")
    func capturePipesAreCloseOnExecAndCloseAfterSuccess() async throws {
        let execution = try makeExecution(executable: "/usr/bin/true")
        let descriptors = try snapshotDescriptors(of: execution)
        #expect(descriptors.count == 8)
        for descriptor in descriptors {
            let flags = fcntl(descriptor.fileDescriptor, F_GETFD)
            #expect(flags != -1)
            #expect(
                flags & FD_CLOEXEC != 0,
                "CommandRunner pipe descriptor \(descriptor.fileDescriptor) can leak into unrelated children"
            )
        }

        let result = await execution.run(timeout: 5)
        #expect(result.exitStatus == 0)
        expectDescriptorsClosed(descriptors)
        #expect(execution.process.terminationHandler == nil)
    }

    @Test("Launch failure closes capture pipes")
    func launchFailureClosesPipes() async throws {
        let execution = try makeExecution(
            executable: "/usr/bin/true",
            directory: URL(
                fileURLWithPath: "/cmux-test-directory-that-does-not-exist-\(UUID().uuidString)"
            )
        )
        let descriptors = try snapshotDescriptors(of: execution)
        let result = await execution.run(timeout: 5)

        #expect(result.executionError != nil)
        expectDescriptorsClosed(descriptors)
    }

    @Test("Abandoning an execution before launch closes every pipe")
    func abandonedExecutionClosesPipes() throws {
        weak var abandonedExecution: CommandExecution?
        var execution: CommandExecution? = try makeExecution(executable: "/usr/bin/true")
        abandonedExecution = execution
        let descriptors = try snapshotDescriptors(of: #require(execution))
        execution = nil

        #expect(abandonedExecution == nil)
        expectDescriptorsClosed(descriptors)
    }

    @Test("Timeout terminates the child and closes capture pipes")
    func timeoutTerminatesAndClosesPipes() async throws {
        let execution = try makeExecution(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 2 &"]
        )
        let descriptors = try snapshotDescriptors(of: execution)
        let result = await execution.run(timeout: 0.1)

        #expect(result.timedOut)
        expectDescriptorsClosed(descriptors)
    }

    @Test("Cancellation before launch closes every pipe")
    func cancellationBeforeLaunchClosesPipes() async throws {
        let execution = try makeExecution(executable: "/usr/bin/true")
        let descriptors = try snapshotDescriptors(of: execution)

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await execution.run(timeout: 5)
        }.value

        #expect(result.timedOut == false)
        #expect(result.executionError != nil)
        expectDescriptorsClosed(descriptors)
    }

    @Test("Task cancellation terminates the child and closes capture pipes")
    func cancellationTerminatesAndClosesPipes() async throws {
        let pidFile = uniqueTemporaryFile(named: "pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let execution = try makeExecution(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s $$ > \"$1\"; exec sleep 30", "cmux-test", pidFile.path]
        )
        let descriptors = try snapshotDescriptors(of: execution)
        let command = Task {
            await execution.run(timeout: 2)
        }

        try await waitForFile(at: pidFile)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(pidText))
        command.cancel()

        let result = await command.value
        #expect(result.timedOut == false)
        #expect(result.executionError != nil)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)

        expectDescriptorsClosed(descriptors)
    }

    private func makeExecution(
        executable: String,
        arguments: [String] = [],
        directory: URL? = nil
    ) throws -> CommandExecution {
        try CommandExecution(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            currentDirectoryURL: directory ?? tempDirectory
        )
    }

    private func snapshotDescriptors(
        of execution: CommandExecution
    ) throws -> [DescriptorIdentity] {
        let descriptors = [
            execution.stdoutPipe.pipe.fileHandleForReading.fileDescriptor,
            execution.stdoutPipe.pipe.fileHandleForWriting.fileDescriptor,
            execution.stderrPipe.pipe.fileHandleForReading.fileDescriptor,
            execution.stderrPipe.pipe.fileHandleForWriting.fileDescriptor,
            execution.cancellationSignal.readDescriptor,
            execution.cancellationSignal.writeDescriptor,
            execution.stdoutReadDescriptor.rawValue,
            execution.stderrReadDescriptor.rawValue,
        ]
        #expect(Set(descriptors).count == descriptors.count)
        return try descriptors.map { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw DescriptorLifecycleTestError.snapshotFailed(descriptor)
            }
            return DescriptorIdentity(
                fileDescriptor: descriptor,
                inode: UInt64(metadata.st_ino)
            )
        }
    }

    private func expectDescriptorsClosed(_ descriptors: [DescriptorIdentity]) {
        for descriptor in descriptors {
            var metadata = stat()
            if fstat(descriptor.fileDescriptor, &metadata) == 0 {
                #expect(
                    UInt64(metadata.st_ino) != descriptor.inode,
                    "CommandRunner retained pipe descriptor \(descriptor.fileDescriptor)"
                )
            } else {
                #expect(errno == EBADF)
            }
        }
    }

    private func uniqueTemporaryFile(named suffix: String) -> URL {
        tempDirectory.appendingPathComponent(
            "cmux-command-runner-\(UUID().uuidString)-\(suffix)",
            isDirectory: false
        )
    }

    private func waitForFile(at url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard clock.now < deadline else {
                throw DescriptorLifecycleTestError.markerTimedOut
            }
            try await clock.sleep(for: .milliseconds(10))
        }
    }

    private struct DescriptorIdentity {
        let fileDescriptor: Int32
        let inode: UInt64
    }

    private enum DescriptorLifecycleTestError: Error {
        case markerTimedOut
        case snapshotFailed(Int32)
    }
}
