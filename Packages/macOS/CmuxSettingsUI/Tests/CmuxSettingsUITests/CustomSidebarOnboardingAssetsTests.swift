import Testing
@testable import CmuxSettingsUI

@Suite
struct CustomSidebarOnboardingAssetsTests {
    @Test
    func loadsStarterTemplate() throws {
        let template = try #require(CustomSidebarOnboardingAssets().starterTemplate())

        #expect(template.suggestedName == "my-sidebar")
        #expect(template.fileExtension == "swift")
        #expect(template.source.contains("ForEach(workspaces)"))
    }

    @Test(arguments: ["agents-board", "btop-agents", "panel-sessions", "panel-subagents", "panel-todo", "workspaces"])
    func loadsBundledExample(id: String) throws {
        let template = try #require(CustomSidebarOnboardingAssets().exampleTemplate(id: id))

        #expect(template.suggestedName == id)
        #expect(template.fileExtension == "js")
        #expect(!template.source.isEmpty)
        #expect(!template.source.contains("cp Examples/CustomSidebars/"))
    }
}
