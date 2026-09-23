import Testing
@testable import CmuxSettings

@Suite("UserFacingSettingDescriptor")
struct UserFacingSettingDescriptorTests {
    /// Verifies the bounded proof settings all carry the shared presentation metadata.
    @Test func representativeAppTogglesCarryCanonicalPresentationMetadata() throws {
        let catalog = SettingCatalog()
        let keys = [
            catalog.app.warnBeforeClosingTab,
            catalog.app.hideTabCloseButton,
            catalog.app.renameSelectsExistingName,
        ]

        for key in keys {
            let descriptor = try #require(key.userFacing)
            #expect(descriptor.section == .app)
            #expect(!descriptor.title.isEmpty)
            #expect(!descriptor.searchID.isEmpty)
            #expect(!descriptor.searchKeywords.isEmpty)
            guard case .toggle(let toggle) = descriptor.control else {
                Issue.record("Expected ordinary toggle metadata")
                continue
            }
            #expect(toggle.commandPalette != nil)
        }
    }

    /// Verifies optional presentation metadata stays outside DefaultsKey equality.
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
