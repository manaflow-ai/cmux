import Darwin
import Foundation
import Testing

import CmuxFoundation
@testable import CmuxRemoteSession

extension RemoteSubprocessTests {
    @Suite("RemoteHostReachabilityProbe descriptor lifecycle")
    struct RemoteHostReachabilityProbeDescriptorTests {
        @Test("Repeated SSH config resolution closes every subprocess pipe")
        func repeatedResolutionClosesPipes() async throws {
            let baseline = openPipeDescriptors()

            for _ in 0..<20 {
                let endpoint = await RemoteHostReachabilityProbe.resolveEndpoint(
                    destination: "nobody@127.0.0.1",
                    port: 2222,
                    identityFile: nil,
                    sshOptions: [],
                    sshConfigFile: "/dev/null"
                )
                let resolved = try #require(endpoint)
                #expect(resolved.host == "127.0.0.1")
                #expect(resolved.port == 2222)
            }

            let leaked = openPipeDescriptors().subtracting(baseline)
            #expect(
                leaked.isEmpty,
                "SSH config resolution retained pipe descriptors after its children exited: \(leaked.sorted())"
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

        private func openPipeDescriptors() -> Set<Int32> {
            var descriptors: Set<Int32> = []
            for descriptor in 0..<getdtablesize() {
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0,
                      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO) else {
                    continue
                }
                descriptors.insert(descriptor)
            }
            return descriptors
        }
    }
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
