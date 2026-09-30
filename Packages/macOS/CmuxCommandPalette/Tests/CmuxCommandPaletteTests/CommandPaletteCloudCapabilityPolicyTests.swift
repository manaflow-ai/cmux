import CmuxCommandPalette
import Testing

@Suite("Command palette Cloud capability policy")
struct CommandPaletteCloudCapabilityPolicyTests {
    @Test("classifies representative shared, Cloud-only, and local-only commands")
    func representativeCommandsHaveExpectedCapabilities() {
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.newTerminalTab") == .shared
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.terminalSplitRight") == .shared
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.browserBack") == .shared
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.cloud.status") == .cloudOnly
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.cloud.fork") == .cloudOnly
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.cloud.newMachine") == .shared
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.browserSplitRight") == .localOnly
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.openDirectoryDiffViewer") == .localOnly
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.capability(for: "palette.terminalOpenDirectory.finder") == .localOnly
        )
    }

    @Test("scopes Cloud-only and local-only commands to the workspace context")
    func contextAllowsOnlyValidCapabilities() {
        let localContext = CommandPaletteContextSnapshot()
        var cloudContext = CommandPaletteContextSnapshot()
        cloudContext.setBool(CommandPaletteContextKeys.workspaceIsCloud, true)

        #expect(
            CommandPaletteCloudCapabilityPolicy.allows(
                commandId: "palette.terminalSplitRight",
                context: localContext
            )
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.allows(
                commandId: "palette.terminalSplitRight",
                context: cloudContext
            )
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.allows(
                commandId: "palette.cloud.status",
                context: cloudContext
            )
        )
        #expect(
            !CommandPaletteCloudCapabilityPolicy.allows(
                commandId: "palette.cloud.status",
                context: localContext
            )
        )
        #expect(
            !CommandPaletteCloudCapabilityPolicy.allows(
                commandId: "palette.browserSplitRight",
                context: cloudContext
            )
        )
        #expect(
            CommandPaletteCloudCapabilityPolicy.allows(
                commandId: "palette.browserSplitRight",
                context: localContext
            )
        )
    }
}
