import Testing
@testable import CmuxHerdrResume

@Suite("herdr resume invocation")
struct HerdrResumeInvocationTests {
    private func parse(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) -> HerdrResumeInvocation? {
        HerdrResumeInvocation(arguments: arguments, environment: environment)
    }

    /// A named attach keeps its session and the directory it ran in.
    @Test("Named session attach")
    func namedSessionAttach() throws {
        let invocation = try #require(
            parse(["herdr", "--session", "manu"], environment: ["PWD": "/tmp/project"])
        )

        #expect(invocation == HerdrResumeInvocation(
            executable: "herdr",
            sessionName: "manu",
            workingDirectory: "/tmp/project"
        ))
        #expect(invocation.arguments == ["herdr", "--session", "manu"])
        #expect(invocation.shellCommand == "'herdr' '--session' 'manu'")
    }

    /// The cmux launch directory wins over the shell's PWD.
    @Test("Launch directory wins over PWD")
    func launchDirectoryWinsOverPWD() throws {
        let invocation = try #require(parse(
            ["herdr"],
            environment: ["PWD": "/tmp/shell", "CMUX_AGENT_LAUNCH_CWD": "/tmp/launch"]
        ))

        #expect(invocation.workingDirectory == "/tmp/launch")
    }

    /// An empty launch directory falls back to the shell's PWD.
    @Test("Empty launch directory falls back to PWD", arguments: ["", "  "])
    func emptyLaunchDirectoryFallsBackToPWD(launchDirectory: String) throws {
        let invocation = try #require(parse(
            ["herdr"],
            environment: ["PWD": "/tmp/shell", "CMUX_AGENT_LAUNCH_CWD": launchDirectory]
        ))

        #expect(invocation.workingDirectory == "/tmp/shell")
    }

    /// A bare attach resumes the session that HERDR_SESSION selected.
    @Test("Bare attach follows HERDR_SESSION")
    func bareAttachFollowsSessionEnvironment() throws {
        let invocation = try #require(parse(["herdr"], environment: ["HERDR_SESSION": "work"]))

        #expect(invocation.sessionName == "work")
        #expect(invocation.arguments == ["herdr", "--session", "work"])
    }

    /// A session argument wins over HERDR_SESSION, as it does in herdr.
    @Test("Session argument wins over HERDR_SESSION", arguments: [
        (["herdr", "--session", "manu"], "manu"),
        (["herdr", "--session=kunden"], "kunden"),
        (["herdr", "session", "attach", "lsd"], "lsd"),
    ])
    func sessionArgumentWinsOverEnvironment(arguments: [String], session: String) throws {
        let invocation = try #require(parse(arguments, environment: ["HERDR_SESSION": "work"]))

        #expect(invocation.sessionName == session)
    }

    /// An empty HERDR_SESSION is herdr's default session.
    @Test("Empty HERDR_SESSION is the default session")
    func emptySessionEnvironmentIsDefaultSession() throws {
        let invocation = try #require(parse(["herdr"], environment: ["HERDR_SESSION": ""]))

        #expect(invocation.sessionName == nil)
        #expect(invocation.arguments == ["herdr"])
    }

    /// herdr ignores a HERDR_SESSION name it rejects, so cmux does not guess.
    @Test("Unusable HERDR_SESSION fails closed", arguments: [
        " ", " work ", "a b", "work!", "a/b", "wörk", "-x",
    ])
    func unusableSessionEnvironmentFailsClosed(value: String) {
        #expect(parse(["herdr"], environment: ["HERDR_SESSION": value]) == nil)
    }

    /// A bare attach keeps the executable path the process ran.
    @Test("Default session attach keeps the observed executable")
    func defaultSessionAttach() throws {
        let invocation = try #require(parse(["/Users/test/.local/bin/herdr"]))

        #expect(invocation.sessionName == nil)
        #expect(invocation.workingDirectory == nil)
        #expect(invocation.arguments == ["/Users/test/.local/bin/herdr"])
        #expect(invocation.shellCommand == "'/Users/test/.local/bin/herdr'")
    }

    /// `session attach <name>` and `--session=<name>` resume as `--session <name>`.
    @Test("Other attach spellings normalize to --session", arguments: [
        (["herdr", "session", "attach", "lsd"], "lsd"),
        (["herdr", "--session=kunden"], "kunden"),
    ])
    func attachSpellingsNormalize(arguments: [String], session: String) throws {
        let invocation = try #require(parse(arguments))

        #expect(invocation.sessionName == session)
        #expect(invocation.arguments == ["herdr", "--session", session])
    }

    /// A quote in the session name cannot break out of the shell command.
    @Test("Session name is shell quoted")
    func sessionNameIsShellQuoted() throws {
        let invocation = try #require(parse(["herdr", "--session", "it's"]))

        #expect(invocation.shellCommand == "'herdr' '--session' 'it'\\''s'")
    }

    /// Server, socket subcommands, remote attaches and unknown options fail closed.
    @Test("Non-attach herdr invocations are rejected", arguments: [
        ["/Users/test/.local/bin/herdr", "server"],
        ["herdr", "server", "stop"],
        ["herdr", "pane", "list"],
        ["herdr", "agent", "list"],
        ["herdr", "workspace", "list"],
        ["herdr", "api", "snapshot"],
        ["herdr", "plugin", "action", "invoke", "state-start"],
        ["herdr", "session", "list"],
        ["herdr", "update"],
        ["herdr", "--help"],
        ["herdr", "--remote", "workbox"],
        ["herdr", "--remote", "workbox", "--session", "manu"],
        ["herdr", "--machine", "workbox", "pane", "list"],
        ["herdr", "--session", "manu", "pane", "list"],
        ["herdr", "--session"],
        ["herdr", "--session", "--remote"],
        ["herdr", "--session="],
    ])
    func nonAttachInvocationsAreRejected(arguments: [String]) {
        #expect(parse(arguments) == nil)
    }

    /// A client started inside a herdr pane is not the surface's own attach.
    @Test("Client nested inside a herdr pane is rejected")
    func nestedClientIsRejected() {
        #expect(HerdrResumeInvocation.isInsideHerdrPane(environment: ["HERDR_ENV": "1"]))
        #expect(!HerdrResumeInvocation.isInsideHerdrPane(environment: [:]))
        #expect(parse(["herdr", "--session", "manu"], environment: ["HERDR_ENV": "1"]) == nil)
    }

    /// Missing arguments and other executables never read as a herdr attach.
    @Test("Missing or foreign arguments are rejected", arguments: [
        [],
        ["/usr/bin/vim", "--session", "manu"],
        ["herdr-radar", "--session", "manu"],
    ])
    func missingOrForeignArgumentsAreRejected(arguments: [String]) {
        #expect(parse(arguments) == nil)
    }
}
