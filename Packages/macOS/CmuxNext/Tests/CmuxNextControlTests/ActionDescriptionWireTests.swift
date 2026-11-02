import CmuxNextActions
@testable import CmuxNextControl
import Testing

/// `action.list` and `action.describe` carry an action's own prose as
/// `description` (`ActionDescriptor.description`), which `cmux action describe`
/// prints and the cmux MCP server puts first in the action's tool description.
@MainActor
@Suite struct ActionDescriptionWireTests {
    static func info(description: String?) -> ControlActionInfo {
        var info = ControlActionInfo(id: "cloudExec", title: "Run Command on Cloud Machine…", category: "cloud", categoryTitle: "Cloud",
                                     cliName: "cloud exec", symbol: "terminal.fill", keywords: [], shortcut: nil, shortcutConfig: nil,
                                     arguments: [], targets: ["machine"], requiresMask: 0, requires: [],
                                     isBound: true, isDebugOnly: false, mainMenu: nil)
        info.description = description
        return info
    }

    @Test func theWireFormCarriesTheDescription() {
        let json = Self.info(description: "Runs a shell command.").json(contextMask: 0, debugActionsAvailable: false)
        #expect(json["description"] == .string("Runs a shell command."))
    }

    @Test func anActionWithoutOneHasNoDescriptionMember() {
        let json = Self.info(description: nil).json(contextMask: 0, debugActionsAvailable: false)
        #expect(json["description"] == nil)
    }

    @Test func theCatalogTakesItFromTheDescriptor() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "cloudExec" })
        let expected = try #require(descriptor.description)
        let catalog = RegistryControlBridge.catalog(from: ActionRegistry.standard())
        let action = try #require(catalog.resolve("cloud exec"))
        #expect(action.description == expected)
        #expect(catalog.json(action)["description"] == .string(expected))
    }
}
