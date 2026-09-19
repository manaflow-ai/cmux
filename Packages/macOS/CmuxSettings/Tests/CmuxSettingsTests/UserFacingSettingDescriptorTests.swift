import Testing
@testable import CmuxSettings

@Suite("UserFacingSettingDescriptor")
struct UserFacingSettingDescriptorTests {
    @Test func representativeAppTogglesCarryCanonicalPresentationMetadata() throws {
        let catalog = SettingCatalog()
        let keys = [
            catalog.app.warnBeforeClosingTab,
            catalog.app.hideTabCloseButton,
            catalog.app.renameSelectsExistingName,
        ]

        for key in keys {
            let descriptor = try #require(key.userFacing)
            #expect(descriptor.sectionID == "app")
            #expect(descriptor.controlKind == .toggle)
            #expect(!descriptor.title.isEmpty)
            #expect(!descriptor.searchID.isEmpty)
            #expect(!descriptor.searchKeywords.isEmpty)
            #expect(descriptor.commandPaletteToggle != nil)
        }
    }

    @Test func presentationMetadataDoesNotChangeDefaultsKeyEquality() {
        let catalogKey = SettingCatalog().app.warnBeforeClosingTab
        let storageEquivalent = DefaultsKey<Bool>(
            id: catalogKey.id,
            defaultValue: catalogKey.defaultValue,
            userDefaultsKey: catalogKey.userDefaultsKey,
            suite: catalogKey.suite,
            legacyUserDefaultsKeys: catalogKey.legacyUserDefaultsKeys
        )

        #expect(catalogKey == storageEquivalent)
    }
}
