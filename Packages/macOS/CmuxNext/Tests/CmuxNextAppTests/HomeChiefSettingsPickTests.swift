import AppKit
@testable import CmuxNextDaemon
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Testing

/// The Chief Settings pickers write the brain's engine. A harness pick starts
/// the new harness on its own model and effort (another harness's model would
/// not run), as the Chief editor in Home and Settings does; a pick the brain
/// refuses shows what the brain still runs, not the refused value.
@MainActor @Suite struct HomeChiefSettingsPickTests {
    @Test func aNewHarnessStartsOnItsOwnModelAndEffort() async throws {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: RecordingChief(writes: continuation))
        await view.refresh().value
        let codex = try #require(view.harness.itemArray.firstIndex { $0.representedObject as? String == ChiefBackend.codex.id })
        view.harness.selectItem(at: codex)
        view.picked(view.harness)
        var received = writes.makeAsyncIterator()
        let write = await received.next()
        let expected: [String: String?] = ["harness": "codex", "model": nil, "effort": nil, "speed": nil]
        #expect(write == expected)
    }

    @Test func aRefusedPickShowsWhatTheBrainStillRuns() async throws {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                         source: RecordingChief(writes: continuation, refuses: true))
        await view.refresh().value
        #expect(view.effort.selectedItem?.representedObject as? String == "high")
        let low = try #require(view.effort.itemArray.firstIndex { $0.representedObject as? String == "low" })
        // The person picks Low; the brain refuses it.
        view.effort.selectItem(at: low)
        await view.pick("effort", "low").value
        #expect(view.effort.selectedItem?.representedObject as? String == "high")
    }

    /// The Harness popup reads this Mac's acpmux harnesses at each refresh (a harness added to
    /// acpmux shows the next time the card opens) for a Chief whose brain runs here.
    @Test func theHarnessPopupOffersEveryAcpmuxHarness() async throws {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: RecordingChief(writes: continuation))
        view.listHarnesses = { ["claude", "opencode", "gemini"] }
        await view.refresh().value
        let offered = view.harness.itemArray.compactMap { $0.representedObject as? String }
        #expect(offered.contains("opencode"), "offered: \(offered)")
        #expect(offered.contains("gemini"), "offered: \(offered)")
        #expect(offered.filter { $0 == "claude" }.count == 1)
    }

    /// Picking by name the harness Default already runs keeps the model and effort chosen for it.
    @Test func theHarnessDefaultRunsKeepsTheModelAndEffort() {
        var onDefault = HomeChiefSnapshot(harness: nil, model: "claude-opus-5-5", effort: "high", avatar: nil, turns: [])
        onDefault.effective = ChiefEngineReport.Engine(harness: "claude", model: "claude-opus-5-5", effort: "high")
        #expect(HomeChiefSettingsView.keepsHarness("claude", shown: onDefault))
        #expect(HomeChiefSettingsView.keepsHarness(nil, shown: onDefault))
        #expect(!HomeChiefSettingsView.keepsHarness("codex", shown: onDefault))
        var onClaude = onDefault
        onClaude.harness = "claude"
        #expect(HomeChiefSettingsView.keepsHarness("claude", shown: onClaude))
        // What Default would run is not known while a harness is chosen.
        #expect(!HomeChiefSettingsView.keepsHarness(nil, shown: onClaude))
        #expect(!HomeChiefSettingsView.keepsHarness("claude", shown: nil))
    }
}

/// A brain on Claude with Opus at high effort that records each write, and
/// refuses every write when `refuses` is set.
private struct RecordingChief: HomeChiefEngineSource {
    let writes: AsyncStream<[String: String?]>.Continuation
    var refuses = false
    var isLocal: Bool { true }
    var place: String? { nil }

    static var start: HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: "claude", model: "claude-opus-5-5", effort: "high", avatar: nil, turns: [])
        snapshot.efforts = ["low", "high"]
        return snapshot
    }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { Self.start }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        writes.yield(fields)
        if refuses { throw .refused(reason: "invalid_effort", message: "refused") }
        return Self.start
    }
}
