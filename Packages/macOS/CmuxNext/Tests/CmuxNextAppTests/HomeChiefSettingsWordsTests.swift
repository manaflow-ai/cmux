import AppKit
@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import Testing

/// The Chief Settings card in words a person reads: effort levels by name, not the brain's ids
/// ("xhigh"); counts with their plural ("1 tool call"); and one Diagnostics control for
/// VoiceOver and Tab, not the triangle and its title as two.
@MainActor @Suite struct HomeChiefSettingsWordsTests {
    @Test func effortLevelsShowByName() {
        var snapshot = HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: [])
        snapshot.efforts = ["minimal", "low", "medium", "high", "xhigh", "max", "turbo"]
        snapshot.effective = ChiefEngineReport.Engine(harness: "claude", model: nil, effort: "xhigh")
        let titles = HomeChiefEngineTitles(snapshot)
        #expect(titles.efforts.map(\.value) == snapshot.efforts)
        // An effort the app does not know shows as the brain names it.
        #expect(titles.efforts.map(\.title) == ["Minimal", "Low", "Medium", "High", "Extra High", "Max", "turbo"])
        #expect(titles.defaultEffort == String(format: HomeEngineStrings.defaultNamedFormat, "Extra High"))
    }

    @Test func theLastTurnCountsInTheirPlural() throws {
        let one = try #require(HomeEngineTurn(line: #"{"ev":"turn.end","harness":"claude","ms":1500,"tools":1,"tool_errors":1}"#))
        #expect(HomeEngineStrings.lastTurn(one).contains("1 tool call (1 failed)"))
        let many = try #require(HomeEngineTurn(line: #"{"ev":"turn.end","harness":"claude","ms":1500,"tools":3,"tool_errors":0}"#))
        #expect(HomeEngineStrings.lastTurn(many).contains("3 tool calls (0 failed)"))
    }

    @Test func diagnosticsIsOneControl() {
        let home = FileManager.default.temporaryDirectory
        // This Mac's brain with no daemon connected: it reads the files and sets nothing.
        let view = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), lanes: BackgroundWork(label: "test.chief-engine"), connection: { nil }))
        // The tree as VoiceOver walks it: a button is never an element itself, its cell is, so a
        // walk of views' isAccessibilityElement() finds nothing.
        let named = AccessibilityAudit().nodes(under: view).filter { $0.label == HomeEngineStrings.diagnostics }
        #expect(named.map(\.role) == [.disclosureTriangle])
        #expect(named.first?.element === view.diagnosticsToggle.cell)
    }
}
