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

    @Test(arguments: ["focus", "activity"])
    func loadsBundledExample(id: String) throws {
        let template = try #require(CustomSidebarOnboardingAssets().exampleTemplate(id: id))

        #expect(template.suggestedName == id)
        #expect(template.fileExtension == "js")
        #expect(!template.source.isEmpty)
    }
}
