import XCTest
@testable import CmuxSettingsUI

final class CmuxSettingsJSONPathModelTests: XCTestCase {
    func testPathModelsAreSortedAndSectioned() {
        let paths = CmuxSettingsJSONPathList.all

        XCTAssertEqual(paths.map(\.path), paths.map(\.path).sorted())
        XCTAssertEqual(
            CmuxSettingsJSONPathModel(
                descriptor: .init(path: "terminal.showScrollBar")
            ).section,
            "terminal"
        )
    }
}
