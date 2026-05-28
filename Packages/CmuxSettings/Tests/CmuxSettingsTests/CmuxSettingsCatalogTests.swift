import XCTest
@testable import CmuxSettings

final class CmuxSettingsCatalogTests: XCTestCase {
    func testSupportedJSONPathsContainCurrentSettingsSurface() {
        XCTAssertTrue(CmuxSettingsCatalog.supportedJSONPaths.contains("app.appearance"))
        XCTAssertTrue(CmuxSettingsCatalog.supportedJSONPaths.contains("terminal.autoResumeAgentSessions"))
        XCTAssertTrue(CmuxSettingsCatalog.supportedJSONPaths.contains("browser.defaultSearchEngine"))
        XCTAssertTrue(CmuxSettingsCatalog.supportedJSONPaths.contains("shortcuts.bindings"))
    }

    func testDefaultPrimaryURLUsesCmuxJSON() {
        let home = URL(fileURLWithPath: "/tmp/cmux-settings-home", isDirectory: true)
        XCTAssertEqual(
            CmuxSettingsCatalog.defaultPrimaryURL(homeDirectoryURL: home).path,
            "/tmp/cmux-settings-home/.config/cmux/cmux.json"
        )
    }
}
