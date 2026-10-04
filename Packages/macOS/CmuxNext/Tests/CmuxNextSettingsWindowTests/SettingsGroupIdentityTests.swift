import CmuxNextSettings
@testable import CmuxNextSettingsWindow
import Testing

/// A group's title is its view identity (`SettingsGroup.id`): a section
/// that lists one group in two runs draws the first run twice. Every
/// section's groups must have distinct titles.
@MainActor
@Suite struct SettingsGroupIdentityTests {
    @Test func everySectionListsEachGroupOnce() {
        for section in SettingsSection.allCases {
            let titles = SettingsWindowModel.grouped(SettingsSchema.settings(in: section)).map(\.title)
            #expect(Set(titles).count == titles.count, "\(section.rawValue): \(titles)")
        }
    }
}
