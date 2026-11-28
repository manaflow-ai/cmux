import Testing

@testable import CmuxSettings

@Suite("Mobile artifact folder access")
struct MobileArtifactFolderAccessTests {
    @Test("defaults to subtree access")
    func defaultValue() {
        #expect(SettingCatalog().mobile.artifactFolderAccess.defaultValue == .subtree)
    }

    @Test("one-level value round-trips through settings storage")
    func oneLevelRoundTrip() {
        let encoded = MobileArtifactFolderAccess.oneLevel.encodeForUserDefaults()
        #expect(MobileArtifactFolderAccess.decodeFromUserDefaults(encoded) == .oneLevel)
    }
}
