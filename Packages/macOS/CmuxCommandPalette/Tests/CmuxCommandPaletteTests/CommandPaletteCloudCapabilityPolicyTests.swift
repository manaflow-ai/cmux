import CmuxCommandPalette
import Testing

@Suite("Command palette Cloud capability policy")
struct CommandPaletteCloudCapabilityPolicyTests {
    private let policy = CommandPaletteCloudCapabilityPolicy()

    /// Representative command IDs cover each capability classification.
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
            policy.capability(for: "palette.cloud.restore") == .shared
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
        #expect(
            policy.capability(for: "palette.openTerminalChatView") == .localOnly
        )
    }

    /// The audited sets stay explicit so a new palette action cannot silently drift.
    @Test("keeps the audited Cloud and local-only command sets explicit")
    func auditedCapabilitySetsRemainStable() {
        let cloudOnly = [
            "palette.cloud.fork",
            "palette.cloud.snapshot",
            "palette.cloud.promoteTemplate",
            "palette.cloud.status",
            "palette.cloud.ports",
            "palette.cloud.tools",
            "palette.cloud.handoff",
        ]
        let localOnly = [
            "palette.newBrowserWorkspace",
            "palette.newAgentChat",
            "palette.newBrowserTab",
            "palette.newSimulatorPane",
            "palette.openFolder",
            "palette.openFolderInVSCodeInline",
            "palette.openWorkspacePullRequests",
            "palette.openDiffViewer",
            "palette.openDirectoryDiffViewer",
            "palette.findInDirectory",
            "palette.vscodeServeWebStop",
            "palette.vscodeServeWebRestart",
            "palette.terminalAttachTextBoxFile",
            "palette.browserSplitRight",
            "palette.browserSplitDown",
            "palette.terminalSplitBrowserRight",
            "palette.terminalSplitBrowserDown",
            "palette.openTerminalChatView",
            "palette.terminalOpenDirectory.finder",
        ]

        #expect(cloudOnly.allSatisfy { policy.capability(for: $0) == .cloudOnly })
        #expect(localOnly.allSatisfy { policy.capability(for: $0) == .localOnly })
        #expect(policy.capability(for: "palette.newTerminalTab") == .shared)
        #expect(policy.capability(for: "palette.browserBack") == .shared)
        #expect(policy.capability(for: "palette.cloud.restore") == .shared)
    }

    /// Context gating allows only capabilities valid for the selected workspace.
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
        #expect(
            policy.allows(
                commandId: "palette.cloud.restore",
                context: localContext
            )
        )
        #expect(
            policy.allows(
                commandId: "palette.cloud.restore",
                context: cloudContext
            )
        )
        #expect(
            !policy.allows(
                commandId: "palette.openTerminalChatView",
                context: cloudContext
            )
        )
        #expect(
            policy.allows(
                commandId: "palette.openTerminalChatView",
                context: localContext
            )
        )
    }
}
