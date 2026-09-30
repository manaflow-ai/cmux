import CmuxCommandPalette
import Testing

@Suite("Command palette Cloud capability policy")
struct CommandPaletteCloudCapabilityPolicyTests {
    private let policy = CommandPaletteCloudCapabilityPolicy()

    @Test("classifies representative shared, Cloud-only, and local-only commands")
    func representativeCommandsHaveExpectedCapabilities() {
        #expect(
            policy.capability(for: "palette.newTerminalTab") == .shared
        )
        #expect(
            policy.capability(for: "palette.terminalSplitRight") == .shared
        )
        #expect(
            policy.capability(for: "palette.browserBack") == .shared
        )
        #expect(
            policy.capability(for: "palette.cloud.status") == .cloudOnly
        )
        #expect(
            policy.capability(for: "palette.cloud.fork") == .cloudOnly
        )
        #expect(
            policy.capability(for: "palette.cloud.newMachine") == .shared
        )
        #expect(
            policy.capability(for: "palette.browserSplitRight") == .localOnly
        )
        #expect(
            policy.capability(for: "palette.openDirectoryDiffViewer") == .localOnly
        )
        #expect(
            policy.capability(for: "palette.terminalOpenDirectory.finder") == .localOnly
        )
    }

    @Test("scopes Cloud-only and local-only commands to the workspace context")
    func contextAllowsOnlyValidCapabilities() {
        let localContext = CommandPaletteContextSnapshot()
        var cloudContext = CommandPaletteContextSnapshot()
        cloudContext.setBool(CommandPaletteContextKeys.workspaceIsCloud, true)

        #expect(
            policy.allows(
                commandId: "palette.terminalSplitRight",
                context: localContext
            )
        )
        #expect(
            policy.allows(
                commandId: "palette.terminalSplitRight",
                context: cloudContext
            )
        )
        #expect(
            policy.allows(
                commandId: "palette.cloud.status",
                context: cloudContext
            )
        )
        #expect(
            !policy.allows(
                commandId: "palette.cloud.status",
                context: localContext
            )
        )
        #expect(
            !policy.allows(
                commandId: "palette.browserSplitRight",
                context: cloudContext
            )
        )
        #expect(
            policy.allows(
                commandId: "palette.browserSplitRight",
                context: localContext
            )
        )
    }
}
