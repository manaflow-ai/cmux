import AppKit
@testable import CmuxNextDaemon
import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-20 ("we need a more comprehensive model and harness picker"): the Chief
/// popover's Model popup listed acpmux's ids flat, an alias beside the release it runs
/// ("Opus" and "Claude Opus 5.5"), every effort for every model, no Fast, and "Default" did not
/// say what it runs. The picker groups by family, keeps one row per model, sets the 1M context
/// variant beside its model, offers only the efforts the model takes, and Fast where it runs.
@MainActor @Suite struct HomeChiefModelMenuTests {
    /// What Claude Code's acpmux reports (live list over the catalog), in its order.
    static let claudeModels: [ChiefEngineReport.Model] = [
        .init(id: "default", name: "Default (recommended)", resolvedModel: "claude-opus-5-5"),
        .init(id: "opus", name: "Opus", resolvedModel: "claude-opus-5-5"),
        .init(id: "opus[1m]", name: "Opus (1M context)", resolvedModel: "claude-opus-5-5"),
        .init(id: "opusplan", name: "Opus Plan Mode"),
        .init(id: "claude-opus-5-5", name: "Claude Opus 5.5", family: "Opus", provider: "anthropic", shortName: "Opus 5.5",
              efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium", fast: true,
              aliases: ["opus"], releaseDate: "2026-09-01"),
        .init(id: "claude-opus-4-5", name: "Claude Opus 4.5", family: "Opus", provider: "anthropic", shortName: "Opus 4.5",
              efforts: ["low", "medium", "high"], defaultEffort: "medium", releaseDate: "2025-11-24"),
        .init(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", family: "Sonnet", provider: "anthropic",
              shortName: "Sonnet 5.5", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium",
              aliases: ["sonnet"], releaseDate: "2026-09-01"),
        .init(id: "sonnet", name: "Sonnet", resolvedModel: "claude-sonnet-5-5"),
        .init(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", family: "Haiku", provider: "anthropic",
              shortName: "Haiku 4.5", fast: false, releaseDate: "2025-10-15"),
    ]

    static func snapshot(model: String? = nil, effort: String? = nil, speed: String? = nil,
                         speeds: [String] = ["default"]) -> HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: nil, model: model, effort: effort, avatar: nil, turns: [])
        snapshot.speed = speed
        snapshot.models = claudeModels
        snapshot.efforts = ["minimal", "low", "medium", "high", "xhigh", "max"]
        snapshot.speeds = speeds
        snapshot.effective = ChiefEngineReport.Engine(harness: "claude", model: model, effort: effort)
        return snapshot
    }

    @Test func theModelPopupShowsSectionsAndSelectsTheChosenModel() async throws {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                         source: MenuChief(start: Self.snapshot(model: "sonnet", effort: "xhigh"), writes: continuation))
        await view.refresh().value
        #expect(view.model.itemArray.filter(\.isSectionHeader).map(\.title).contains("Opus"))
        #expect(view.model.selectedItem?.representedObject as? String == "sonnet")
        #expect(view.model.selectedItem?.title == "Sonnet 5.5")
        // Picking Opus 4.5, which has no Extra High, clears the effort in the same write.
        let older = try #require(view.model.itemArray.firstIndex { $0.representedObject as? String == "claude-opus-4-5" })
        view.model.selectItem(at: older)
        view.picked(view.model)
        var received = writes.makeAsyncIterator()
        let write = await received.next()
        let expected: [String: String?] = ["model": "claude-opus-4-5", "effort": nil]
        #expect(write == expected)
    }

    @Test func speedShowsOnlyWhereFastRuns() async throws {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let claude = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                           source: MenuChief(start: Self.snapshot(model: "opus"), writes: continuation))
        await claude.refresh().value
        #expect(claude.speed.superview?.isHidden == true)

        let codex = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                          source: MenuChief(start: Self.snapshot(model: "opus", speeds: ["default", "fast"]),
                                                            writes: continuation))
        await codex.refresh().value
        #expect(codex.speed.superview?.isHidden == false)
        let fast = try #require(codex.speed.itemArray.firstIndex { $0.representedObject as? String == "fast" })
        codex.speed.selectItem(at: fast)
        codex.picked(codex.speed)
        var received = writes.makeAsyncIterator()
        let write = await received.next()
        let expected: [String: String?] = ["speed": "fast"]
        #expect(write == expected)

        // A model that has no fast tier hides the row.
        let haiku = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                          source: MenuChief(start: Self.snapshot(model: "claude-haiku-4-5", speeds: ["default", "fast"]),
                                                            writes: continuation))
        await haiku.refresh().value
        #expect(haiku.speed.superview?.isHidden == true)
    }

    @Test func aModelPickIsRememberedAsRecent() async throws {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let defaults = try #require(UserDefaults(testSuiteName: "HomeChiefModelMenuTests-\(UUID().uuidString)"))
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                         source: MenuChief(start: Self.snapshot(model: "opus"), writes: continuation))
        view.recents = HomeChiefModelRecents(defaults: defaults)
        await view.refresh().value
        await view.pick("model", "claude-haiku-4-5").value
        #expect(HomeChiefModelRecents(defaults: defaults).models(harness: "claude") == ["claude-haiku-4-5"])
    }
}

/// A brain that answers `start` to every read and write, recording each write.
private struct MenuChief: HomeChiefEngineSource {
    let start: HomeChiefSnapshot
    let writes: AsyncStream<[String: String?]>.Continuation
    var isLocal: Bool { true }
    var place: String? { nil }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { start }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        writes.yield(fields)
        return start
    }
}
