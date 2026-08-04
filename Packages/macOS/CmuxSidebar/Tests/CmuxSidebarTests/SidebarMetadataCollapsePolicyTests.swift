import Testing
@testable import CmuxSidebar

@Suite("SidebarMetadataCollapsePolicy")
struct SidebarMetadataCollapsePolicyTests {
    private let entries = (0..<400).map {
        SidebarStatusEntry(key: "metadata-\($0)", value: "value-\($0)")
    }

    @Test(arguments: [
        (configuredLimit: 3, entryCount: 8, expectedVisibleCount: 3, showsToggle: true),
        (configuredLimit: 6, entryCount: 8, expectedVisibleCount: 6, showsToggle: true),
        (configuredLimit: 0, entryCount: 8, expectedVisibleCount: 8, showsToggle: false),
        (configuredLimit: 500, entryCount: 250, expectedVisibleCount: 250, showsToggle: false),
    ])
    func resolvesCollapsedEntries(
        configuredLimit: Int,
        entryCount: Int,
        expectedVisibleCount: Int,
        showsToggle: Bool
    ) {
        let policy = SidebarMetadataCollapsePolicy(configuredLimit: configuredLimit)
        let candidateEntries = Array(entries.prefix(entryCount))

        #expect(policy.visibleEntries(candidateEntries, isExpanded: false).count == expectedVisibleCount)
        #expect(policy.showsExpansionToggle(entryCount: entryCount) == showsToggle)
    }

    @Test
    func unlimitedLargeSetAlwaysShowsEveryEntry() {
        let policy = SidebarMetadataCollapsePolicy(configuredLimit: 0)

        #expect(policy.visibleEntries(entries, isExpanded: false) == entries)
        #expect(!policy.showsExpansionToggle(entryCount: entries.count))
        #expect(policy.visibleEntries(entries, isExpanded: true) == entries)
    }
}
