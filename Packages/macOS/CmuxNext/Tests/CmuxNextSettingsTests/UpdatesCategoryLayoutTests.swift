import CmuxNextSettings
import Testing

/// Settings > Updates is its own category, right after General, holding how this Mac updates.
/// General no longer holds the update rows.
struct UpdatesCategoryLayoutTests {
    private static let categories = SettingsPageLayout().categories()

    @Test func updatesHoldsTheUpdateRowsRightAfterGeneral() throws {
        let updates = try #require(Self.categories.first { $0.spec.id == "updates" })
        #expect(updates.groups.flatMap(\.rows).contains("updates.channel"))
        #expect(Self.categories.map(\.spec.id).prefix(2) == ["general", "updates"])
    }

    @Test func generalNoLongerHoldsThem() throws {
        let general = try #require(Self.categories.first { $0.spec.id == "general" })
        #expect(!general.groups.flatMap(\.rows).contains { $0.hasPrefix("updates.") })
    }
}
