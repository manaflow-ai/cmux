import AppKit
@testable import CmuxNextDaemon
import CmuxNextHome
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
        #expect(titles.defaultHarness == Self.named(ChiefBackend.claude.title))
        // The model shows by the name acpmux offers, and acpmux's own "default" is not an item.
        #expect(titles.defaultModel == Self.named("Opus 5.5"))
        #expect(titles.models.map(\.value) == ["claude-opus-5-5"])
        #expect(titles.defaultEffort == Self.named(HomeEngineStrings.effortTitle("high")))
    }

    /// The effective engine includes the owner's choice, so a chosen field's
    /// Default cannot say what it would run: it stays plain beside the choice.
    @Test func aChosenFieldsDefaultStaysPlain() {
        var snapshot = HomeChiefSnapshot(harness: nil, model: "claude-opus-5-5", effort: nil, avatar: nil, turns: [])
        snapshot.models = [ChiefEngineReport.Model(id: "claude-opus-5-5", name: "Opus 5.5")]
        snapshot.effective = ChiefEngineReport.Engine(harness: "claude", model: "claude-opus-5-5", effort: "high")
        let titles = HomeChiefEngineTitles(snapshot)
        #expect(titles.defaultModel == HomeEngineStrings.defaultValue)
        #expect(titles.defaultHarness == Self.named(ChiefBackend.claude.title))
    }

    @Test func defaultStaysPlainUntilTheBrainAnswers() {
        let titles = HomeChiefEngineTitles(HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: []))
        #expect(titles.defaultHarness == HomeEngineStrings.defaultValue)
        #expect(titles.defaultModel == HomeEngineStrings.defaultValue)
        #expect(HomeChiefEngineTitles.titled("default") == HomeEngineStrings.defaultValue)
    }

    @Test func aReplyWithNoTextHasNoEmptyQuotes() throws {
        let empty = try #require(HomeEngineTurn(line: #"{"ev":"turn.end","harness":"claude","ms":1300,"reply":{"prefix":""}}"#))
        #expect(HomeEngineStrings.reply(empty) == "claude")
        let none = try #require(HomeEngineTurn(line: #"{"ev":"turn.end","harness":"claude","model":"opus","ms":1300}"#))
        #expect(HomeEngineStrings.reply(none) == "claude, opus")
        let text = try #require(HomeEngineTurn(line: #"{"ev":"turn.end","harness":"claude","ms":1300,"reply":{"prefix":"Done."}}"#))
        #expect(HomeEngineStrings.reply(text) == "\u{201C}Done.\u{201D} claude")
    }

    /// The popover is the quick version (Leo 2026-10-20): its All Chief Settings link opens the
    /// Settings page with every Chief setting, whichever brain the card shows.
    @Test func allChiefSettingsOpensTheSettingsPage() throws {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: OfflineChief())
        var opened = 0
        view.onAllSettings = { opened += 1 }
        let link = try #require(Self.subviews(of: view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "cmux.home.chief.allSettings" })
        #expect(!link.isHidden)
        #expect(link.accessibilityLabel() == HomeEngineStrings.allChiefSettings)
        link.performClick(nil)
        #expect(opened == 1)
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { subviews(of: $0) }
    }

    @Test func diagnosticsStartClosedAndTheNameIsTheOnlyField() throws {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: OfflineChief())
        #expect(!view.showsDiagnostics)
        let fields = Self.editableFields(in: view)
        #expect(fields.map { $0.accessibilityLabel() } == [HomeEngineStrings.name])
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width == HomeChiefSettingsView.width)
        // The name field runs from beside the avatar to the card's trailing inset.
        let box = try #require(fields.first?.superview)
        let trailing = view.convert(box.bounds, from: box).maxX
        #expect(abs(trailing - (HomeChiefSettingsView.width - HomeChiefSettingsView.inset)) < 1)
    }

    @Test func leavingAnUnchangedNameRenamesNothing() async {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: OfflineChief())
        var renamed: [String] = []
        view.onRename = { renamed.append($0); return nil }
        view.setName("Chief")
        #expect(view.commitName() == nil)
        view.nameField.stringValue = "  Ada  "
        await view.commitName()?.value
        #expect(view.commitName() == nil)
        #expect(renamed == ["Ada"])
    }

    /// A Chief always has a name: clearing the field and leaving it renames nothing and shows
    /// the name again, rather than an empty field over a Chief that kept its name.
    @Test func clearingTheNameShowsItAgain() async {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: OfflineChief())
        var renamed: [String] = []
        view.onRename = { renamed.append($0); return nil }
        view.setName("Chief")
        view.nameField.stringValue = "   "
        view.renamed()
        #expect(renamed.isEmpty)
        #expect(view.nameField.stringValue == "Chief")
        // A name with spaces around it is saved and shown trimmed.
        view.nameField.stringValue = "  Ada  "
        await view.commitName()?.value
        #expect(renamed == ["Ada"])
        #expect(view.nameField.stringValue == "Ada")
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

    static func named(_ value: String) -> String { String(format: HomeEngineStrings.defaultNamedFormat, value) }

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
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
}
