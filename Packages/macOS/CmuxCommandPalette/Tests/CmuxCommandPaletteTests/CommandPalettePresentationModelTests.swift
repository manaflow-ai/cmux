import Foundation
import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite("CommandPalettePresentationModel")
struct CommandPalettePresentationModelTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "CommandPalettePresentationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func makeModel(defaults: UserDefaults) -> CommandPalettePresentationModel {
        CommandPalettePresentationModel(
            defaultWorkspaceDescriptionHeight: 42,
            defaults: defaults
        )
    }

    @Test("seeds default workspace-description height and empty transient state")
    func seedsDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults: defaults)
        #expect(model.workspaceDescriptionHeight == 42)
        #expect(model.query.isEmpty)
        #expect(model.selectedResultIndex == 0)
        #expect(model.resultsRevision == 0)
        #expect(model.usageHistoryByCommandId.isEmpty)
    }

    @Test("recordUsage increments count and stamps the provided time")
    func recordUsageIncrements() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults: defaults)
        model.recordUsage("cmd.a", now: 100)
        model.recordUsage("cmd.a", now: 200)
        model.recordUsage("cmd.b", now: 150)
        #expect(model.usageHistoryByCommandId["cmd.a"]?.useCount == 2)
        #expect(model.usageHistoryByCommandId["cmd.a"]?.lastUsedAt == 200)
        #expect(model.usageHistoryByCommandId["cmd.b"]?.useCount == 1)
        #expect(model.usageHistoryByCommandId["cmd.b"]?.lastUsedAt == 150)
    }

    @Test("persistence round-trips through the frozen defaults key")
    func persistenceRoundTrips() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = makeModel(defaults: defaults)
        writer.recordUsage("cmd.x", now: 321)

        // A fresh model reading the same defaults reloads the persisted history.
        let reader = makeModel(defaults: defaults)
        reader.refreshUsageHistory()
        #expect(reader.usageHistoryByCommandId["cmd.x"]?.useCount == 1)
        #expect(reader.usageHistoryByCommandId["cmd.x"]?.lastUsedAt == 321)
    }

    @Test("persisted payload is JSON under the frozen key, matching the legacy format")
    func persistedPayloadIsLegacyJSON() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults: defaults)
        model.recordUsage("cmd.y", now: 7)

        // The legacy inline code wrote a JSON-encoded [String: CommandPaletteUsageEntry]
        // under "commandPalette.commandUsage.v1"; verify both the key and the shape.
        #expect(CommandPalettePresentationModel.usageHistoryDefaultsKey == "commandPalette.commandUsage.v1")
        let data = try #require(defaults.data(forKey: CommandPalettePresentationModel.usageHistoryDefaultsKey))
        let decoded = try JSONDecoder().decode([String: CommandPaletteUsageEntry].self, from: data)
        #expect(decoded["cmd.y"]?.useCount == 1)
        #expect(decoded["cmd.y"]?.lastUsedAt == 7)
    }

    @Test("corrupt persisted data falls back to empty history")
    func corruptDataFallsBack() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: CommandPalettePresentationModel.usageHistoryDefaultsKey)
        let model = makeModel(defaults: defaults)
        model.refreshUsageHistory()
        #expect(model.usageHistoryByCommandId.isEmpty)
    }
}
