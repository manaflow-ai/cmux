import AppKit
@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Testing

/// Leo 2026-10-19 ("kinda yikes"): the Chief Settings sidebar showed a raw
/// "Avatar" text field, pickers that all read "Default", the trace stats in
/// the body and an empty `“”` in "answered by". The settings card names what
/// "Default" runs, keeps the diagnostics behind a closed disclosure, has no
/// avatar text field, and quotes only a reply that has text.
@MainActor @Suite struct HomeChiefSettingsViewTests {
    @Test func defaultNamesWhatTheBrainRuns() {
        var snapshot = HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: [])
        snapshot.models = [ChiefEngineReport.Model(id: "default", name: "Default"),
                           ChiefEngineReport.Model(id: "claude-opus-5-5", name: "Opus 5.5")]
        snapshot.efforts = ["low", "high"]
        snapshot.effective = ChiefEngineReport.Engine(harness: "claude", model: "claude-opus-5-5", effort: "high")
        let titles = HomeChiefEngineTitles(snapshot)
        #expect(titles.defaultHarness == "Default (claude)")
        // The model shows by the name acpmux offers, and acpmux's own "default" is not an item.
        #expect(titles.defaultModel == "Default (Opus 5.5)")
        #expect(titles.models.map(\.value) == ["claude-opus-5-5"])
        #expect(titles.defaultEffort == "Default (high)")
    }

    @Test func defaultStaysPlainUntilTheBrainAnswers() {
        let titles = HomeChiefEngineTitles(HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: []))
        #expect(titles.defaultHarness == "Default")
        #expect(titles.defaultModel == "Default")
        #expect(HomeChiefEngineTitles.titled("default") == "Default")
    }

    @Test func aReplyWithNoTextHasNoEmptyQuotes() throws {
        let empty = try #require(HomeEngineTurn(line: #"{"ev":"turn.end","harness":"claude","ms":1300,"reply":{"prefix":""}}"#))
        #expect(HomeEngineStrings.reply(empty) == "claude")
        let none = try #require(HomeEngineTurn(line: #"{"ev":"turn.end","harness":"claude","model":"opus","ms":1300}"#))
        #expect(HomeEngineStrings.reply(none) == "claude, opus")
        let text = try #require(HomeEngineTurn(line: #"{"ev":"turn.end","harness":"claude","ms":1300,"reply":{"prefix":"Done."}}"#))
        #expect(HomeEngineStrings.reply(text) == "\u{201C}Done.\u{201D} claude")
    }

    @Test func diagnosticsStartClosedAndTheNameIsTheOnlyField() {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: OfflineChief())
        #expect(!view.showsDiagnostics)
        #expect(Self.editableFields(in: view).map { $0.accessibilityLabel() } == ["Name"])
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width == HomeChiefSettingsView.width)
    }

    @Test func appearanceRowsGrowTheCard() {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: OfflineChief())
        var resized = 0
        view.onResize = { resized += 1 }
        view.layoutSubtreeIfNeeded()
        let before = view.fittingSize.height
        view.addAppearanceRow("Bubble Style", control: NSPopUpButton(frame: .zero, pullsDown: false))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height > before)
        #expect(resized == 1)
    }

    static func editableFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        for subview in view.subviews { found += editableFields(in: subview) }
        return found
    }
}

/// A Chief whose brain is not running.
private struct OfflineChief: HomeChiefEngineSource {
    var isLocal: Bool { true }
    var place: String? { nil }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
    func set(_ key: String, _ value: String?) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
}
