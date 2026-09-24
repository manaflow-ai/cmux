import Testing
@testable import CmuxMobileShellModel

struct MobileBuildTypeMigrationTests {
    @Test(arguments: ["dev.cmux.app.beta", "dev.cmux.app.internal"])
    func onlyExistingTestDistributionsImportLegacyComputers(bundleID: String) {
        #expect(MobileBuildType.resolve(isDebugBuild: false, bundleIdentifier: bundleID)
            .migratesLegacyComputerIdentities)
        #expect(!MobileBuildType.resolve(isDebugBuild: true, bundleIdentifier: bundleID)
            .migratesLegacyComputerIdentities)
    }

    @Test(arguments: ["com.cmux.app", "dev.cmux.app", "dev.cmux.app.demo", "unknown"])
    func appStoreAndOtherDistributionsNeverImportLegacyComputers(bundleID: String) {
        #expect(!MobileBuildType.resolve(isDebugBuild: false, bundleIdentifier: bundleID)
            .migratesLegacyComputerIdentities)
    }
}
