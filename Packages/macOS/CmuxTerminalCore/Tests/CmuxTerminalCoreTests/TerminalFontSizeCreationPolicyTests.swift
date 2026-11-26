import CmuxTerminalCore
import Foundation
import Testing

@Suite struct TerminalFontSizeCreationPolicyTests {
    @Test func inheritPreservesConfiguration() throws {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.setFontSize(13, isExplicitOverride: true)
        inherited.fontSizeChangeToken = UUID()
        inherited.fontSizeChangeTokens = [UUID(), UUID()]
        inherited.workingDirectory = "/tmp/inherited"
        inherited.command = "echo inherited"
        inherited.environmentVariables = ["CMUX_TEST": "inherited"]
        inherited.initialInput = "pwd\n"
        inherited.waitAfterCommand = true

        let applied = try #require(
            TerminalFontSizeCreationPolicy.inherit.applying(to: inherited)
        )

        #expect(applied.fontSizeLineage == inherited.fontSizeLineage)
        #expect(applied.fontSizeChangeToken == inherited.fontSizeChangeToken)
        #expect(
            applied.fontSizeChangeTokens
                == inherited.fontSizeChangeTokens
        )
        #expect(applied.workingDirectory == inherited.workingDirectory)
        #expect(applied.command == inherited.command)
        #expect(applied.environmentVariables == inherited.environmentVariables)
        #expect(applied.initialInput == inherited.initialInput)
        #expect(applied.waitAfterCommand == inherited.waitAfterCommand)
    }

    @Test func sessionRestoreAppliesExplicitOverride() throws {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.setFontSize(11, isExplicitOverride: false)
        inherited.fontSizeChangeToken = UUID()
        inherited.fontSizeChangeTokens = [UUID()]

        let applied = try #require(
            TerminalFontSizeCreationPolicy.sessionRestore(overrideBasePoints: 15)
                .applying(to: inherited)
        )

        #expect(applied.fontSizeLineage == TerminalFontSizeLineage(
            basePoints: 15,
            isExplicitOverride: true
        ))
        #expect(applied.fontSizeChangeToken == nil)
        #expect(applied.fontSizeChangeTokens.isEmpty)
    }

    @Test func sessionRestorePreservesRepresentedChangeTokens() throws {
        let representedChangeTokens = Set([UUID(), UUID()])
        let explicit = try #require(
            TerminalFontSizeCreationPolicy.sessionRestore(
                overrideBasePoints: 15,
                representedChangeTokens: representedChangeTokens
            ).applying(to: nil)
        )
        let followsConfig = try #require(
            TerminalFontSizeCreationPolicy.sessionRestore(
                overrideBasePoints: nil,
                representedChangeTokens: representedChangeTokens
            ).applying(to: nil)
        )

        #expect(explicit.fontSizeLineage == TerminalFontSizeLineage(
            basePoints: 15,
            isExplicitOverride: true
        ))
        #expect(explicit.fontSizeChangeToken == nil)
        #expect(
            explicit.fontSizeChangeTokens
                == representedChangeTokens
        )
        #expect(followsConfig.fontSizeLineage == nil)
        #expect(followsConfig.fontSizeChangeToken == nil)
        #expect(
            followsConfig.fontSizeChangeTokens
                == representedChangeTokens
        )
    }

    @Test(arguments: [
        nil,
        Float32.zero,
        -1,
        Float32.nan,
        Float32.infinity,
        511,
        Float32.greatestFiniteMagnitude,
    ] as [Float32?])
    func invalidSessionRestoreClearsOnlyFontLineage(
        overrideBasePoints: Float32?
    ) throws {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.setFontSize(13, isExplicitOverride: true)
        inherited.fontSizeChangeToken = UUID()
        inherited.fontSizeChangeTokens = [UUID()]
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
        #expect(applied.fontSizeChangeToken == nil)
        #expect(applied.fontSizeChangeTokens.isEmpty)
        #expect(applied.workingDirectory == inherited.workingDirectory)
        #expect(applied.command == inherited.command)
        #expect(applied.environmentVariables == inherited.environmentVariables)
        #expect(applied.initialInput == inherited.initialInput)
        #expect(applied.waitAfterCommand == inherited.waitAfterCommand)
    }

    @Test func sessionRestoreAcceptsMaximumPersistableBaseFontSize() throws {
        let applied = try #require(
            TerminalFontSizeCreationPolicy.sessionRestore(overrideBasePoints: 510)
                .applying(to: nil)
        )

        #expect(applied.fontSizeLineage == TerminalFontSizeLineage(
            basePoints: 510,
            isExplicitOverride: true
        ))
    }
}
