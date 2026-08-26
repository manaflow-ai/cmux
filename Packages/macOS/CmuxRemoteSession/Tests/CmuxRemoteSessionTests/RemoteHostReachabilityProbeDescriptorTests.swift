import Darwin
import Foundation
import Testing

@testable import CmuxFoundation
@testable import CmuxRemoteSession

extension RemoteSubprocessTests {
    @Suite("RemoteHostReachabilityProbe descriptor lifecycle")
    struct RemoteHostReachabilityProbeDescriptorTests {
        @Test("Repeated SSH config resolution closes every subprocess pipe")
        func repeatedResolutionClosesPipes() async throws {
            let commandRunner = DescriptorAuditingSSHConfigCommandRunner()

            for _ in 0..<20 {
                let endpoint = await RemoteHostReachabilityProbe.resolveEndpoint(
                    destination: "nobody@127.0.0.1",
                    port: 2222,
                    identityFile: nil,
                    sshOptions: [],
                    sshConfigFile: "/dev/null",
                    commandRunner: commandRunner
                )
                let resolved = try #require(endpoint)
                #expect(resolved.host == "127.0.0.1")
                #expect(resolved.port == 2222)
            }

            let audit = await commandRunner.audit
            #expect(audit.invocations == 20)
            #expect(
                audit.retainedDescriptors.isEmpty,
                "SSH config resolution retained its execution descriptors: \(audit.retainedDescriptors.sorted())"
            )
        }

        @Test("SSH config resolution uses the shared command runner")
        func resolutionUsesSharedCommandRunner() async throws {
            let commandRunner = RecordingSSHConfigCommandRunner()
            let endpoint = await RemoteHostReachabilityProbe.resolveEndpoint(
                destination: "cmux-test",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                sshConfigFile: "/dev/null",
                commandRunner: commandRunner
            )

            let resolved = try #require(endpoint)
            #expect(resolved.host == "resolved.example.com")
            #expect(resolved.port == 2200)
            let invocations = await commandRunner.invocations
            let invocation = try #require(invocations.first)
            #expect(invocation.executable == "/usr/bin/ssh")
            #expect(invocation.arguments == ["-G", "-F", "/dev/null", "cmux-test"])
            #expect(invocation.timeout == 3.0)
        }
    }
}

private actor DescriptorAuditingSSHConfigCommandRunner: CommandRunning {
    struct Audit: Sendable {
        var invocations = 0
        var retainedDescriptors: Set<Int32> = []
    }

    private(set) var audit = Audit()

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        do {
            let execution = try CommandExecution(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                currentDirectoryURL: URL(fileURLWithPath: directory)
            )
            let descriptors = try descriptorIdentities(of: execution)
            let result = await execution.run(timeout: timeout)
            audit.invocations += 1
            audit.retainedDescriptors.formUnion(
                descriptors.compactMap { $0.isStillOpen ? $0.fileDescriptor : nil }
            )
            return result
        } catch {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: String(describing: error)
            )
        }
    }

    private func descriptorIdentities(
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
        guard Set(descriptors).count == descriptors.count else {
            throw DescriptorAuditError.duplicateDescriptor
        }
        return try descriptors.map { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw DescriptorAuditError.snapshotFailed(descriptor)
            }
            return DescriptorIdentity(
                fileDescriptor: descriptor,
                inode: UInt64(metadata.st_ino)
            )
        }
    }
}

private struct DescriptorIdentity: Sendable {
    let fileDescriptor: Int32
    let inode: UInt64

    var isStillOpen: Bool {
        var metadata = stat()
        return fstat(fileDescriptor, &metadata) == 0
            && UInt64(metadata.st_ino) == inode
    }
}

private enum DescriptorAuditError: Error {
    case duplicateDescriptor
    case snapshotFailed(Int32)
}

private actor RecordingSSHConfigCommandRunner: CommandRunning {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private(set) var invocations: [Invocation] = []

    func run(
        directory _: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations.append(Invocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        return CommandResult(
            stdout: "hostname resolved.example.com\nport 2200\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
