import AppKit
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief Settings card's Automations block (issue 25573): the Chief's automations from its brain
/// (`chief.automation.list`), each with what starts it and when it runs next, and Pause, Resume and
/// Delete (`chief.automation.update`). A brain that keeps none (a hosted cloud Chief) hides the block.
@MainActor @Suite struct HomeChiefAutomationRowsTests {
    /// The brain's list as optchat-chief `Automation::to_json` writes it.
    nonisolated static let brainList = Data(#"""
    {"automations": [
      {"id": "au1", "name": "Morning PRs", "prompt": "Summarize my open PRs",
       "trigger": {"type": "schedule", "cron": "0 9 * * *", "summary": "on the schedule `0 9 * * *`"},
       "paused": false, "created_ms": 1793000000000, "next_ms": 1793091600000, "last_fired_ms": null, "runs": 0},
      {"id": "au2", "name": "Review fixes", "prompt": "Review the finished fix",
       "trigger": {"type": "agent_done", "matches": "fix", "summary": "when a subagent whose title has \"fix\" finishes"},
       "paused": true, "created_ms": 1793000000000, "next_ms": null, "runs": 2},
      {"id": "au3", "name": "Review", "prompt": "Review it", "trigger": {"type": "agent_done"}, "paused": false,
       "created_ms": 1, "runs": 0},
      {"id": "au4", "name": "Later", "prompt": "x", "trigger": {"type": "webhook_from_the_future"}, "created_ms": 1}
    ]}
    """#.utf8)

    nonisolated static func automations() throws -> [ChiefAutomation] {
        try JSONDecoder().decode(ChiefAutomationList.self, from: brainList).automations
    }

    @Test func theBrainsListDecodes() throws {
        let list = try Self.automations()
        #expect(list.map(\.id) == ["au1", "au2", "au3", "au4"])
        #expect(list[0].trigger == .schedule(cron: "0 9 * * *"))
        #expect(list[0].nextMs == 1_793_091_600_000)
        #expect(list[1].trigger == .agentDone(matches: "fix"))
        #expect(list[1].paused && list[1].runs == 2)
        #expect(list[2].trigger == .agentDone(matches: nil))
        #expect(list[3].trigger == .other("webhook_from_the_future"), "a newer brain's trigger still decodes")
    }

    @Test func eachRowSaysWhatStartsItAndWhenItRunsNext() throws {
        let list = try Self.automations()
        let utc = try #require(TimeZone(identifier: "UTC"))
        let next = HomeChiefAutomationRows.detail(list[0], locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(next.hasPrefix(String(format: HomeEngineStrings.automationScheduleFormat, "0 9 * * *")))
        #expect(next.contains("9:00"), "\(next)")
        let paused = HomeChiefAutomationRows.detail(list[1])
        #expect(paused.hasPrefix(String(format: HomeEngineStrings.automationAgentDoneMatchingFormat, "fix")))
        #expect(paused.hasSuffix(HomeEngineStrings.automationPaused))
        #expect(HomeChiefAutomationRows.detail(list[2]) == HomeEngineStrings.automationAgentDone)
    }

    @Test func pauseResumeAndDeleteGoToTheBrain() async throws {
        let brain = AutomatingChief(list: try Self.automations())
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: brain)
        await view.refreshAutomations().value
        #expect(view.showsAutomations)
        #expect(!view.automationsHeader.isHidden)
        #expect(view.automationRows.shown.map(\.id) == ["au1", "au2", "au3", "au4"])

        await view.changeAutomation("au1", .pause).value
        #expect(await brain.updates() == [UpdateCall(id: "au1", action: .pause)])
        #expect(view.automationRows.shown.first?.paused == true, "the row shows the brain's list after the change")

        await view.changeAutomation("au2", .delete).value
        #expect(view.automationRows.shown.map(\.id) == ["au1", "au3", "au4"])

        // An id the brain no longer has: the card says so and keeps the list.
        await view.changeAutomation("au9", .resume).value
        #expect(!view.failure.isHidden)
        #expect(view.automationRows.shown.count == 3)
        // The next change that takes clears that note.
        await view.changeAutomation("au1", .resume).value
        #expect(view.failure.isHidden)
        #expect(view.automationRows.shown.first?.paused == false)
    }

    @Test func theRowsButtonsSendTheirAction() async throws {
        let rows = HomeChiefAutomationRows(width: 288)
        var sent: [UpdateCall] = []
        rows.onAction = { id, action in sent.append(UpdateCall(id: id, action: action)) }
        rows.show(try Self.automations())
        let buttons = Self.buttons(in: rows)
        let pause = try #require(buttons.first { $0.accessibilityIdentifier() == "cmux.home.chief.automation.au1.pause" })
        let resume = try #require(buttons.first { $0.accessibilityIdentifier() == "cmux.home.chief.automation.au2.resume" })
        let delete = try #require(buttons.first { $0.accessibilityIdentifier() == "cmux.home.chief.automation.au3.delete" })
        for button in [pause, resume, delete] { button.performClick(nil) }
        #expect(sent == [UpdateCall(id: "au1", action: .pause), UpdateCall(id: "au2", action: .resume),
                         UpdateCall(id: "au3", action: .delete)])
    }

    @Test func noAutomationsSaysHowToMakeOne() {
        let rows = HomeChiefAutomationRows(width: 288)
        rows.show([])
        let texts = rows.arrangedSubviews.compactMap { ($0 as? ThemedLabel)?.stringValue }
        #expect(texts == [HomeEngineStrings.automationsEmpty])
    }

    @Test func aBrainWithoutAutomationsHidesTheBlock() async {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                         source: AutomatingChief(list: [], supported: false))
        await view.refreshAutomations().value
        #expect(!view.showsAutomations)
        #expect(view.automationsHeader.isHidden)
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub -> [NSButton] in
            (sub as? NSButton).map { [$0] } ?? [] + buttons(in: sub)
        }
    }
}

struct UpdateCall: Equatable, Sendable {
    var id: String
    var action: ChiefAutomationAction
}

/// A brain with automations: it applies each update to its list, as optchat-chief does.
private actor AutomatingChief: HomeChiefEngineSource {
    private var list: [ChiefAutomation]
    private var calls: [UpdateCall] = []
    let supported: Bool
    nonisolated var isLocal: Bool { true }
    nonisolated var place: String? { nil }

    init(list: [ChiefAutomation], supported: Bool = true) {
        self.list = list
        self.supported = supported
    }

    func updates() -> [UpdateCall] { calls }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        HomeChiefSnapshot(harness: "claude", model: nil, effort: nil, avatar: nil, turns: [])
    }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        try await read()
    }

    func automations() async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        guard supported else { throw .unsupported }
        return list
    }

    func updateAutomation(_ id: String, _ action: ChiefAutomationAction) async throws(HomeChiefEngineError) -> [ChiefAutomation] {
        guard supported else { throw .unsupported }
        calls.append(UpdateCall(id: id, action: action))
        guard let index = list.firstIndex(where: { $0.id == id }) else {
            throw .refused(reason: "not_found", message: "no automation \(id)")
        }
        switch action {
        case .pause: list[index].paused = true
        case .resume: list[index].paused = false
        case .delete: list.remove(at: index)
        case .run: list[index].runs += 1
        }
        return list
    }
}
