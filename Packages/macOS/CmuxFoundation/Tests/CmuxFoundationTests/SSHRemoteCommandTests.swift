import Testing
@testable import CmuxFoundation

@Suite("SSH remote command boundary")
struct SSHRemoteCommandTests {
    @Test("preserves exact TTY flags and persists their effective OpenSSH state")
    func preservesTTYFlagSequence() {
        let command = SSHRemoteCommand(
            undelimitedArguments: ["-T", "-tt", "docker", "exec"]
        )

        #expect(command.ttyRequestArguments == ["-T", "-tt"])
        #expect(command.arguments == ["docker", "exec"])
        #expect(command.sshOptionsPersistingTTYRequest(in: [
            "RequestTTY=yes",
            "ForwardAgent=yes",
        ]) == [
            "ForwardAgent=yes",
            "RequestTTY=force",
        ])
    }

    @Test("follows OpenSSH transitions for repeated clustered t flags")
    func evaluatesRepeatedTTYFlags() {
        let command = SSHRemoteCommand(
            undelimitedArguments: ["-ttt", "printf", "ready"]
        )

        #expect(command.ttyRequestArguments == ["-ttt"])
        #expect(command.sshOptionsPersistingTTYRequest(in: []) == ["RequestTTY=yes"])
    }

    @Test("treats every argument after the separator as a literal command token")
    func preservesDelimitedLeadingTTYToken() {
        let command = SSHRemoteCommand(
            undelimitedArguments: [],
            delimitedArguments: ["-t", "docker", "exec"]
        )

        #expect(command.ttyRequestArguments.isEmpty)
        #expect(command.usesArgumentSeparator)
        #expect(command.arguments == ["-t", "docker", "exec"])
        #expect(command.sshOptionsPersistingTTYRequest(in: ["RequestTTY=no"]) == [
            "RequestTTY=no",
        ])
    }
}
