import Testing
import CMUXAgentLaunch

@Suite("Agent panel title resolver")
struct AgentPanelTitleResolverTests {
    private let resolver = AgentPanelTitleResolver()

    @Test("agent name wins over agent type")
    func nameWinsOverType() {
        let metadata = resolver.metadata(fromArguments: [
            "/opt/claude",
            "--agent-name", "Testare-B",
            "--agent-color", "green",
            "--agent-type", "general-purpose",
        ])

        #expect(metadata?.name == "Testare-B")
        #expect(metadata?.type == "general-purpose")
        #expect(metadata?.displayTitle == "Testare-B")
    }

    @Test("agent type is the fallback when no name is present")
    func typeFallsBackWhenNameIsMissing() {
        let metadata = resolver.metadata(fromArguments: [
            "claude",
            "--agent-type=general-purpose",
        ])

        #expect(metadata?.name == nil)
        #expect(metadata?.type == "general-purpose")
        #expect(metadata?.displayTitle == "general-purpose")
    }

    @Test("shell command wrappers and env assignments are skipped")
    func shellCommandWrappersAreSkipped() {
        let metadata = resolver.metadata(fromCommand: """
            cd '/tmp/work' && env CLAUDECODE=1 /opt/claude --agent-id alice@team --agent-name 'Alice A' --agent-type general-purpose
            """)

        #expect(metadata?.displayTitle == "Alice A")
    }

    @Test("versioned native Claude teammate executables use the agent name")
    func versionedNativeClaudeTeammateUsesAgentName() {
        let title = resolver.title(fromCommands: [
            """
            cd /tmp/work && env CLAUDECODE=1 /Users/austin/.local/share/claude/versions/2.1.233 \
              --agent-id PathScout@session-87b88f27 \
              --agent-name PathScout \
              --team-name session-87b88f27 \
              --agent-color blue \
              --parent-session-id f9b4d8eb-1069-4776-bd4b-ff1da62f2561
            """,
        ])

        #expect(title == "PathScout")
    }

    @Test("nested login shell wrappers are inspected without executing them")
    func nestedLoginShellWrapperIsInspected() {
        let metadata = resolver.metadata(fromCommand: """
            exec -l /bin/sh -lc 'cd /tmp/work && env PATH=/opt/bin /opt/claude --agent-name Nested --agent-type general-purpose'
            """)

        #expect(metadata?.displayTitle == "Nested")
    }

    @Test("Ghostty login and noprofile wrappers still reveal the agent name")
    func ghosttyLoginWrapperIsInspected() {
        let command = #"login -flp austin /bin/bash --noprofile --norc -c 'exec -l /bin/sh -c "cd /tmp/work && env CLAUDECODE=1 /opt/claude --agent-name Testare-B --agent-color green --agent-type general-purpose"'"#

        #expect(resolver.title(fromCommands: [command]) == "Testare-B")
    }

    @Test("a name in a later command wins over an earlier type fallback")
    func nameWinsAcrossLaunchCommandCandidates() {
        #expect(
            resolver.title(fromCommands: [
                "claude --agent-type general-purpose",
                "claude --agent-name Testare-D",
            ]) == "Testare-D"
        )
    }

    @Test("equals and separate value forms are both accepted")
    func acceptsEqualsAndSeparateValueForms() {
        let metadata = resolver.metadata(fromArguments: [
            "claude",
            "--agent-type", "general-purpose",
            "--agent-name=Testare-C",
        ])

        #expect(metadata?.displayTitle == "Testare-C")
    }

    @Test("malformed name falls back to a valid type")
    func malformedNameFallsBackToType() {
        let metadata = resolver.metadata(fromArguments: [
            "claude",
            "--agent-name", "--agent-type",
            "general-purpose",
        ])

        #expect(metadata?.name == nil)
        #expect(metadata?.displayTitle == "general-purpose")
    }

    @Test("prompt arguments after the option terminator are ignored")
    func optionTerminatorStopsMetadataScan() {
        let metadata = resolver.metadata(fromArguments: [
            "claude",
            "--",
            "user prompt mentioning --agent-name", "not-a-panel-name",
        ])

        #expect(metadata == nil)
    }

    @Test("non-Claude commands with agent-shaped arguments are ignored")
    func nonClaudeArgumentVectorIsIgnored() {
        let metadata = resolver.metadata(fromArguments: [
            "python3",
            "worker.py",
            "--agent-name", "ordinary-process",
            "--agent-type", "batch-job",
        ])

        #expect(metadata == nil)
    }

    @Test("a complete teammate envelope does not identify an unrelated executable")
    func nonClaudeIdentityEnvelopeIsIgnored() {
        let metadata = resolver.metadata(fromArguments: [
            "/opt/workers/2.1.233",
            "--agent-id", "Wrong@team",
            "--agent-name", "Wrong",
            "--agent-type", "batch-job",
            "--team-name", "team",
            "--parent-session-id", "f9b4d8eb-1069-4776-bd4b-ff1da62f2561",
        ])

        #expect(metadata == nil)
    }

    @Test("a shell command mentioned as ordinary data is not inspected")
    func shellCommandArgumentIsNotMistakenForAWrapper() {
        let title = resolver.title(fromCommands: [
            "echo /bin/sh -lc 'claude --agent-name Not-An-Agent --agent-type general-purpose'",
        ])

        #expect(title == nil)
    }
}
