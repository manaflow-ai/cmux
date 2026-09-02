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

    @Test("normalizes OpenSSH boolean RequestTTY aliases before applying flags")
    func evaluatesBooleanRequestTTYAliases() {
        let enable = SSHRemoteCommand(
            undelimitedArguments: ["-t", "printf", "ready"]
        )
        let disable = SSHRemoteCommand(
            undelimitedArguments: ["-T"]
        )

        #expect(enable.sshOptionsPersistingTTYRequest(in: ["RequestTTY=true"]) == [
            "RequestTTY=force",
        ])
        #expect(disable.sshOptionsPersistingTTYRequest(in: ["RequestTTY=false"]) == [
            "RequestTTY=no",
        ])
        #expect(enable.sshOptionsPersistingTTYRequest(in: ["RequestTTY = \"yes\""]) == [
            "RequestTTY=force",
        ])
        #expect(disable.disablesTTY(in: ["RequestTTY = \"false\""]))
    }

    @Test("uses the resolved host RequestTTY as the transition baseline")
    func usesResolvedHostRequestTTY() {
        let command = SSHRemoteCommand(
            undelimitedArguments: ["-t", "printf", "ready"]
        )

        #expect(command.sshOptionsPersistingTTYRequest(
            in: [],
            hostRequestTTY: "yes"
        ) == ["RequestTTY=force"])
        #expect(command.sshOptionsPersistingTTYRequest(
            in: [],
            hostRequestTTY: "force"
        ) == ["RequestTTY=yes"])
        #expect(command.sshOptionsPersistingTTYRequest(
            in: ["RequestTTY=no"],
            hostRequestTTY: "force"
        ) == ["RequestTTY=yes"])
    }

    @Test("uses the resolved host RequestTTY when checking disabled TTY")
    func disablesTTYUsesResolvedHostRequestTTY() {
        let command = SSHRemoteCommand(undelimitedArguments: [])
        let explicitTTY = SSHRemoteCommand(undelimitedArguments: ["-t"])

        #expect(command.disablesTTY(in: [], hostRequestTTY: "no"))
        #expect(!command.disablesTTY(in: [], hostRequestTTY: "auto"))
        #expect(!explicitTTY.disablesTTY(in: [], hostRequestTTY: "no"))
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
