import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Customize… (`customize.open`) opens customize-by-asking with no terminal (Leo: "how can i try
/// out the customizations right now?"): a palette row and an app menu row beside Settings…, both
/// running one registered action that opens a new chat with `/customize ` in its composer.
@MainActor
struct CustomizeEntryTests {
    @Test func customizeIsAPaletteRowAndAnAppMenuRowBesideSettings() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == .customizeOpen })
        #expect(action.surfaces.contains(.palette))
        #expect(action.mainMenu == .app)
        let app = try #require(MainMenu.compactActionIDs[.app])
        let settings = try #require(app.firstIndex(of: "openSettings"))
        #expect(app.firstIndex(of: .customizeOpen) == settings + 1)
        #expect(!MainMenu.removedMainMenuActionIDs.contains(.customizeOpen))
    }

    @Test func itRunsNewAgentChatsPathWithTheCustomizeDraft() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var opened: [ActionInvocation] = []
        #expect(registry.bindAgentPane { opened.append($0) })
        #expect(registry.perform(.customizeOpen))
        #expect(opened.count == 1)
        // The new chat's seed takes the draft; it is shown, never sent by itself.
        let seed = AgentHandlers.seed(for: opened.first ?? ActionInvocation())
        #expect(seed.draft == "/customize ")
        #expect(seed.prompt == nil)
        // New Agent Chat itself is unchanged: no draft.
        #expect(AgentHandlers.seed(for: ActionInvocation()).draft == nil)
    }

    @Test func aCallersOwnDraftIsKept() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var opened: [ActionInvocation] = []
        #expect(registry.bindAgentPane { opened.append($0) })
        var invocation = ActionInvocation()
        invocation.arguments["draft"] = .string("/customize make tabs taller")
        #expect(registry.perform(.customizeOpen, invocation: invocation))
        #expect(AgentHandlers.seed(for: opened.first ?? ActionInvocation()).draft == "/customize make tabs taller")
    }

    /// Leo, 2026-11-15 (ask-9634dbcdac): opt-in UI, with turning it off as the way back.
    @Test func rightClickCustomizeIsOneDefaultOffSettingOnEverySurface() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.customizeFromTheAppPath))
        #expect(CmuxConfigSnapshot.customizeFromTheAppDefault == false)
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains(descriptor.id))
        #expect(CmuxConfigSnapshot.empty.customizeFromTheApp == false)
    }

    @Test func rightClickCustomizeIsHiddenUntilTheSettingIsOn() {
        var on = false
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        #expect(registry.bindAgentPane(customizeRows: { on }) { _ in })
        #expect(ActionRegistry.locate(.customizeOpen, in: registry.makeContextMenu(for: .tabStrip)) == nil)
        on = true
        #expect(ActionRegistry.locate(.customizeOpen, in: registry.makeContextMenu(for: .tabStrip)) != nil)
        #expect(registry.descriptor(for: .customizeOpen)?.surfaces.contains(.palette) == true, "the palette row stays")
    }
}
