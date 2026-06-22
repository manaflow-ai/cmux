import Testing
@testable import CmuxCommandPalette

@Suite("CommandPaletteFamilyProviders")
struct CommandPaletteFamilyProvidersTests {
    @Test func viewProviderEmitsLegacyStructure() {
        let contributions = CommandPaletteViewContributionProvider().build(
            strings: CommandPaletteViewContributionProvider.Strings(
                triggerFlashTitle: "Flash Focused Panel",
                triggerFlashSubtitle: "View",
                openTaskManagerTitle: "Task Manager",
                openTaskManagerSubtitle: "Window"
            )
        )
        #expect(contributions.map(\.commandId) == ["palette.triggerFlash", "palette.openTaskManager"])
        let snapshot = CommandPaletteContextSnapshot()
        #expect(contributions[0].title(snapshot) == "Flash Focused Panel")
        #expect(contributions[0].subtitle(snapshot) == "View")
        #expect(contributions[0].keywords == ["flash", "highlight", "focus", "panel"])
        #expect(contributions[1].title(snapshot) == "Task Manager")
        #expect(contributions[1].subtitle(snapshot) == "Window")
        #expect(contributions[1].keywords == ["task", "manager", "process", "cpu", "memory", "kill"])
        // No when-gating in the View slice.
        #expect(contributions.allSatisfy { $0.when(snapshot) })
    }

    @Test func authProviderGatesOnAuthState() throws {
        let contributions = CommandPaletteAuthContributionProvider().build(
            strings: CommandPaletteAuthContributionProvider.Strings(
                signInTitle: "Sign In",
                signOutTitle: "Sign Out",
                subtitle: "Account"
            )
        )
        #expect(contributions.map(\.commandId) == ["palette.auth.signIn", "palette.auth.signOut"])

        let signIn = try #require(contributions.first { $0.commandId == "palette.auth.signIn" })
        let signOut = try #require(contributions.first { $0.commandId == "palette.auth.signOut" })

        var signedOutIdle = CommandPaletteContextSnapshot()
        signedOutIdle.setBool(CommandPaletteContextKeys.authSignedIn, false)
        signedOutIdle.setBool(CommandPaletteContextKeys.authWorking, false)
        #expect(signIn.when(signedOutIdle) == true)
        #expect(signOut.when(signedOutIdle) == false)

        var signedInIdle = CommandPaletteContextSnapshot()
        signedInIdle.setBool(CommandPaletteContextKeys.authSignedIn, true)
        signedInIdle.setBool(CommandPaletteContextKeys.authWorking, false)
        #expect(signIn.when(signedInIdle) == false)
        #expect(signOut.when(signedInIdle) == true)

        var working = CommandPaletteContextSnapshot()
        working.setBool(CommandPaletteContextKeys.authSignedIn, false)
        working.setBool(CommandPaletteContextKeys.authWorking, true)
        #expect(signIn.when(working) == false)
        #expect(signOut.when(working) == false)
    }

    @Test func identifierCopyProviderEmitsLegacyStructureAndGates() throws {
        let contributions = CommandPaletteIdentifierCopyContributionProvider().build(
            strings: CommandPaletteIdentifierCopyContributionProvider.Strings(
                copyWorkspaceID: "Copy Workspace ID",
                copyWorkspaceIDAndRef: "Copy Workspace ID and Ref",
                copyWorkspaceLink: "Copy Workspace Link",
                copyPaneID: "Copy Pane ID",
                copyPaneLink: "Copy Pane Link",
                copySurfaceID: "Copy Surface ID",
                copySurfaceLink: "Copy Surface Link",
                copyIdentifiers: "Copy IDs"
            ),
            workspaceSubtitle: { _ in "ws" },
            panelSubtitle: { _ in "panel" }
        )
        #expect(contributions.map(\.commandId) == [
            "palette.copyWorkspaceID",
            "palette.copyWorkspaceIDAndRef",
            "palette.copyWorkspaceLink",
            "palette.copyPaneID",
            "palette.copyPaneLink",
            "palette.copySurfaceID",
            "palette.copySurfaceLink",
            "palette.copyIdentifiers",
        ])

        let byId = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })

        var hasWorkspace = CommandPaletteContextSnapshot()
        hasWorkspace.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        #expect(byId["palette.copyWorkspaceID"]?.when(hasWorkspace) == true)
        #expect(byId["palette.copyWorkspaceID"]?.when(CommandPaletteContextSnapshot()) == false)
        #expect(byId["palette.copyWorkspaceID"]?.subtitle(hasWorkspace) == "ws")

        var hasPane = CommandPaletteContextSnapshot()
        hasPane.setBool(CommandPaletteContextKeys.panelHasPane, true)
        #expect(byId["palette.copyPaneID"]?.when(hasPane) == true)
        #expect(byId["palette.copyPaneID"]?.when(CommandPaletteContextSnapshot()) == false)

        var hasPanel = CommandPaletteContextSnapshot()
        hasPanel.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        #expect(byId["palette.copySurfaceID"]?.when(hasPanel) == true)
        #expect(byId["palette.copySurfaceID"]?.when(CommandPaletteContextSnapshot()) == false)
        #expect(byId["palette.copySurfaceID"]?.subtitle(hasPanel) == "panel")
    }
}
