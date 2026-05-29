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

    func testKeyboardShortcutAliasesAreInjectedPerSearch() {
        let query = "agent-specific-action"

        XCTAssertFalse(
            searchResultIDs(query: query).contains(
                SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts")
            )
        )

        XCTAssertTrue(
            searchResultIDs(
                query: query,
                keyboardShortcutActionAliases: "agent-specific-action"
            )
            .contains(SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts"))
        )
    }

    private func searchResultIDs(
        query: String,
        keyboardShortcutActionAliases: String = ""
    ) -> Set<String> {
        Set(
            SettingsSearchIndex
                .entries(
                    matching: query,
                    keyboardShortcutActionAliases: keyboardShortcutActionAliases
                )
                .map(\.id)
        )
    }
}
