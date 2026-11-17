import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

/// Settings search must not offer the Chief card's rows while the host
/// doesn't offer Chief (https://github.com/manaflow-ai/cmux/issues/26003).
@Suite("Settings sidebar Chief visibility")
struct SettingsSidebarChiefVisibilityTests {
    private static let chiefEntryIDs: Set<String> = [
        "setting:automation:chief",
        "setting:automation:chief-harness",
        "setting:automation:chief-model",
        "setting:automation:chief-effort",
        "setting:automation:chief-dangerous-permissions",
    ]

    private func visibleIDs(matching query: String, isChiefAvailable: Bool) -> Set<String> {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        return Set(index.match(query).filter {
            SettingsSidebarEntryVisibility.isVisible(
                $0,
                isCloudSectionAvailable: true,
                isChiefAvailable: isChiefAvailable
            )
        }.map(\.id))
    }

    @Test func chiefSearchRowsAreHiddenWhileChiefIsUnavailable() {
        let shown = visibleIDs(matching: "chief", isChiefAvailable: true)
        #expect(Self.chiefEntryIDs.isSubset(of: shown))

        let hidden = visibleIDs(matching: "chief", isChiefAvailable: false)
        #expect(hidden.isDisjoint(with: Self.chiefEntryIDs))
        #expect(visibleIDs(matching: "permission prompts", isChiefAvailable: false)
            .isDisjoint(with: Self.chiefEntryIDs))
    }

    @Test func otherAutomationRowsStayVisibleWhileChiefIsUnavailable() {
        let shown = visibleIDs(matching: "agent messages", isChiefAvailable: false)
        #expect(shown.contains("setting:automation:agent-messages"))
    }
}
