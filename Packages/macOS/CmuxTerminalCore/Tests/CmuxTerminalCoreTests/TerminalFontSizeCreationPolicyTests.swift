import CmuxTerminalCore
import Testing

@Suite struct TerminalFontSizeCreationPolicyTests {
    @Test func inheritPreservesConfiguration() throws {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.setFontSize(13, isExplicitOverride: true)
        inherited.workingDirectory = "/tmp/inherited"
        inherited.command = "echo inherited"
        inherited.environmentVariables = ["CMUX_TEST": "inherited"]
        inherited.initialInput = "pwd\n"
        inherited.waitAfterCommand = true

        let applied = try #require(
            TerminalFontSizeCreationPolicy.inherit.applying(to: inherited)
        )

        #expect(applied.fontSizeLineage == inherited.fontSizeLineage)
        #expect(applied.workingDirectory == inherited.workingDirectory)
        #expect(applied.command == inherited.command)
        #expect(applied.environmentVariables == inherited.environmentVariables)
        #expect(applied.initialInput == inherited.initialInput)
        #expect(applied.waitAfterCommand == inherited.waitAfterCommand)
    }

    @Test func sessionRestoreAppliesExplicitOverride() throws {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.setFontSize(11, isExplicitOverride: false)

        let applied = try #require(
            TerminalFontSizeCreationPolicy.sessionRestore(overrideBasePoints: 15)
                .applying(to: inherited)
        )

        #expect(applied.fontSizeLineage == TerminalFontSizeLineage(
            basePoints: 15,
            isExplicitOverride: true
        ))
    }

    @Test(arguments: [
        nil,
        Float32.zero,
        -1,
        Float32.nan,
        Float32.infinity,
    ] as [Float32?])
    func invalidSessionRestoreClearsOnlyFontLineage(
        overrideBasePoints: Float32?
    ) throws {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.setFontSize(13, isExplicitOverride: true)
        inherited.workingDirectory = "/tmp/restored"
        inherited.command = "echo restored"
        inherited.environmentVariables = ["CMUX_TEST": "restored"]
        inherited.initialInput = "ls\n"
        inherited.waitAfterCommand = true

        let applied = try #require(
            TerminalFontSizeCreationPolicy.sessionRestore(
                overrideBasePoints: overrideBasePoints
            ).applying(to: inherited)
        )

        #expect(applied.fontSizeLineage == nil)
        #expect(applied.workingDirectory == inherited.workingDirectory)
        #expect(applied.command == inherited.command)
        #expect(applied.environmentVariables == inherited.environmentVariables)
        #expect(applied.initialInput == inherited.initialInput)
        #expect(applied.waitAfterCommand == inherited.waitAfterCommand)
    }
}
