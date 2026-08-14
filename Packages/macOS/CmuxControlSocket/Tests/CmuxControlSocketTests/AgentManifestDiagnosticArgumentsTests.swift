import Testing
@testable import CmuxControlSocket

@Suite("Agent manifest diagnostic arguments")
struct AgentManifestDiagnosticArgumentsTests {
    @Test("CLI and v1 socket forms share one accepted grammar")
    func acceptedForms() throws {
        let cli = try AgentManifestDiagnosticArguments.parse(arguments: [
            "--surface=surface:2",
            "--osc",
            "\u{1B}]9;agent;idle\u{07}",
        ]).get()
        let socket = try AgentManifestDiagnosticArguments.parse(
            commandLine: #"--surface "surface:2" --osc "\e]9;agent;idle\a""#
        ).get()

        #expect(cli.surface == "surface:2")
        #expect(cli.osc == "\u{1B}]9;agent;idle\u{07}")
        #expect(socket.surface == "surface:2")
        #expect(socket.osc == "e]9;agent;idlea")
        #expect(try AgentManifestDiagnosticArguments.parse(arguments: []).get() == .init())
        #expect(
            try AgentManifestDiagnosticArguments.parse(arguments: ["pane:3"]).get()
                == .init(surface: "pane:3")
        )
    }

    @Test(
        "Malformed arguments fail closed",
        arguments: [
            (["--surface"], AgentManifestDiagnosticArgumentError.missingValue(option: "--surface")),
            (["--surface="], .emptyValue(option: "--surface")),
            (["--osc", ""], .emptyValue(option: "--osc")),
            (["--osc", "one", "--osc=two"], .duplicateOption(option: "--osc")),
            (["--surface", "one", "two"], .multipleSurfaces),
            (["one", "--surface", "two"], .duplicateOption(option: "--surface")),
            (["--unknown"], .unexpectedArgument("--unknown")),
        ]
    )
    func rejectedForms(
        arguments: [String],
        expected: AgentManifestDiagnosticArgumentError
    ) {
        guard case let .failure(error) = AgentManifestDiagnosticArguments.parse(arguments: arguments) else {
            Issue.record("Malformed arguments were accepted: \(arguments)")
            return
        }
        #expect(error == expected)
    }

    @Test("Unmatched v1 quoting and escaping are rejected")
    func malformedCommandLine() {
        #expect(
            AgentManifestDiagnosticArguments.parse(commandLine: #"--surface "pane:1"#)
                == .failure(.unterminatedQuote("\""))
        )
        #expect(
            AgentManifestDiagnosticArguments.parse(commandLine: "--surface pane:1\\")
                == .failure(.danglingEscape)
        )
    }

    @Test("Argument errors expose their localized CLI description")
    func localizedErrorDescription() {
        #expect(
            AgentManifestDiagnosticArgumentError.missingValue(option: "--surface")
                .errorDescription
                == "debug-agent-manifest requires a value after --surface."
        )
    }
}
