import Testing
@testable import CmuxTerminalAccess

@Suite struct PackageSmokeTests {
    @Test func packageVersionIsExposed() {
        #expect(CmuxTerminalAccess.version == "0.1.0")
    }
}
