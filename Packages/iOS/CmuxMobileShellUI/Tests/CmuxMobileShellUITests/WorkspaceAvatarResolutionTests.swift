import Testing

import CmuxMobileShellModel
@testable import CmuxMobileShellUI

/// Behavior tests for how a workspace row resolves its avatar: a bundled logo
/// identifier encodes/decodes through the `"logo:<id>"` string form, and the
/// precedence is per-workspace avatar over the owning Mac's icon over the
/// default SF Symbol.
@Suite struct WorkspaceAvatarResolutionTests {
    // MARK: MacAvatarIcon classification

    @Test func logoValueRoundTripsToImageCase() {
        let value = MacAvatarIcon.logoValue("claude")
        #expect(value == "logo:claude")
        #expect(MacAvatarIcon.resolve(custom: value, defaultSymbol: "terminal.fill") == .image("claude"))
    }

    @Test func nonPrefixedStringStaysSymbol() {
        #expect(MacAvatarIcon.resolve(custom: "star.fill", defaultSymbol: "terminal.fill") == .symbol("star.fill"))
    }

    @Test func emojiClassifiedAsEmoji() {
        #expect(MacAvatarIcon.resolve(custom: "🚀", defaultSymbol: "terminal.fill") == .emoji("🚀"))
    }

    @Test func emptyOrMissingFallsBackToDefaultSymbol() {
        #expect(MacAvatarIcon.resolve(custom: nil, defaultSymbol: "terminal.fill") == .symbol("terminal.fill"))
        #expect(MacAvatarIcon.resolve(custom: "", defaultSymbol: "terminal.fill") == .symbol("terminal.fill"))
    }

    @Test func emptyLogoIdentifierFallsBack() {
        // "logo:" with no id is malformed; it must not resolve to an empty image.
        #expect(MacAvatarIcon.resolve(custom: "logo:", defaultSymbol: "terminal.fill") == .symbol("terminal.fill"))
    }

    // MARK: Two-source precedence

    @Test func workspaceAvatarWinsOverMachineIcon() {
        let icon = MacAvatarIcon.resolve(
            workspaceAvatar: "logo:claude",
            machineCustomIcon: "desktopcomputer",
            defaultSymbol: "terminal.fill"
        )
        #expect(icon == .image("claude"))
    }

    @Test func machineIconUsedWhenWorkspaceAvatarAbsent() {
        let icon = MacAvatarIcon.resolve(
            workspaceAvatar: nil,
            machineCustomIcon: "desktopcomputer",
            defaultSymbol: "terminal.fill"
        )
        #expect(icon == .symbol("desktopcomputer"))
    }

    @Test func defaultSymbolWhenNeitherSet() {
        let icon = MacAvatarIcon.resolve(
            workspaceAvatar: nil,
            machineCustomIcon: nil,
            defaultSymbol: "terminal.fill"
        )
        #expect(icon == .symbol("terminal.fill"))
    }

    // MARK: Preview integration

    @Test func previewAvatarIconPrefersWorkspaceLogo() {
        var preview = MobileWorkspacePreview(
            id: .init(rawValue: "w1"),
            name: "Build",
            terminals: [],
            avatar: MacAvatarIcon.logoValue("opencode")
        )
        preview.machineCustomIcon = "desktopcomputer"
        #expect(preview.avatarIcon == .image("opencode"))
    }

    @Test func previewAvatarIconFallsBackToMachineIcon() {
        var preview = MobileWorkspacePreview(
            id: .init(rawValue: "w1"),
            name: "Build",
            terminals: []
        )
        preview.machineCustomIcon = "🖥️"
        #expect(preview.avatarIcon == .emoji("🖥️"))
    }

    @Test func previewAvatarIconFallsBackToDefaultSymbol() {
        let preview = MobileWorkspacePreview(
            id: .init(rawValue: "w1"),
            name: "Build",
            terminals: []
        )
        // No avatar, no machine icon: the default terminal-count symbol.
        #expect(preview.avatarIcon == .symbol(preview.avatarSymbolName))
    }

    // MARK: Bundled logo catalog

    @Test func everyCatalogLogoHasABundledAsset() {
        // Guards the wire contract: each identifier the macOS picker can emit
        // must map to a known bundled logo so the phone never shows the neutral
        // fallback for a shipped agent.
        for logo in WorkspaceAgentLogo.allCases {
            #expect(!logo.assetName.isEmpty)
            #expect(!logo.monogram.isEmpty)
        }
    }
}
