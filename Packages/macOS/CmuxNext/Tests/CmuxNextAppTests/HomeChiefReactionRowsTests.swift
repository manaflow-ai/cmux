import AppKit
@testable import CmuxNextDaemon
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Testing

/// The Chief Settings card's Reactions rows (a416): whether a tapback can wake this Chief, and the
/// classifier's harness, model and prompt. Each shows what the brain resolved; "Default" names the
/// person's value (cmux.json), and a value of this Chief's own shows as chosen. A change goes to the
/// brain as one `chief.engine.set` field.
@MainActor @Suite struct HomeChiefReactionRowsTests {
    nonisolated static var resolved: ChiefEngineReport.Engine {
        var engine = ChiefEngineReport.Engine(harness: "claude", model: "claude-opus-5-5", effort: "high")
        engine.classifierHarness = "claude"
        engine.classifierModel = "claude-haiku-5-5"
        engine.classifierPrompt = ""
        engine.reactionsCanWake = true
        return engine
    }

    @Test func theRowsShowTheDefaultsTheBrainResolved() async {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                         source: ReactingChief(writes: continuation, own: nil))
        await view.refresh().value
        let rows = view.reactionRows
        #expect(rows.canWake.selectedItem?.representedObject == nil, "no value of its own: Default")
        #expect(rows.canWake.selectedItem?.title.contains(HomeEngineStrings.reactionsOn) == true)
        #expect(rows.model.stringValue == "")
        #expect(rows.model.placeholderString?.contains("claude-haiku-5-5") == true, "Default names the model it runs")
        #expect(rows.prompt.placeholderString == HomeEngineStrings.reactionPromptBuiltIn)
    }

    @Test func aValueOfItsOwnShowsAsChosen() async {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                         source: ReactingChief(writes: continuation, own: "claude-sonnet-5-5"))
        await view.refresh().value
        #expect(view.reactionRows.model.stringValue == "claude-sonnet-5-5")
        #expect(view.reactionRows.canWake.selectedItem?.representedObject as? String == "false")
    }

    @Test func eachChangeSendsItsField() async throws {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                         source: ReactingChief(writes: continuation, own: nil))
        await view.refresh().value
        var received = writes.makeAsyncIterator()
        let rows = view.reactionRows
        let off = try #require(rows.canWake.itemArray.firstIndex { $0.representedObject as? String == "false" })
        rows.canWake.selectItem(at: off)
        rows.pickedWake(rows.canWake)
        #expect(await received.next() == ["reactions_can_wake": "false"])
        rows.model.stringValue = "claude-sonnet-5-5"
        rows.editedModel(rows.model)
        #expect(await received.next() == ["classifier_model": "claude-sonnet-5-5"])
        rows.prompt.stringValue = "  "
        rows.editedPrompt(rows.prompt)
        let cleared: [String: String?] = ["classifier_prompt": nil]
        #expect(await received.next() == cleared, "an empty field clears this Chief's own value")
    }

    /// The card opens with Name as its only field (diagnosticsStartClosedAndTheNameIsTheOnlyField): the
    /// classifier's harness, model and instructions sit behind a closed Classifier disclosure, and join
    /// the card only when it opens; the Can Wake row shows at once.
    @Test func theClassifierFieldsStartClosedAndOpenOnTheDisclosure() async {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory,
                                         source: ReactingChief(writes: continuation, own: nil))
        await view.refresh().value
        let rows = view.reactionRows
        #expect(!rows.showsClassifier)
        #expect(rows.canWake.isDescendant(of: view), "Can Wake shows at once")
        for field in [rows.harness, rows.model, rows.prompt] { #expect(!field.isDescendant(of: view), "closed: not in the card") }
        rows.classifierToggle.performClick(nil)
        #expect(rows.showsClassifier)
        for field in [rows.harness, rows.model, rows.prompt] { #expect(field.isDescendant(of: view), "open: in the card") }
        #expect(rows.model.placeholderString?.contains("claude-haiku-5-5") == true, "filled before it opened")
        rows.classifierToggle.performClick(nil)
        #expect(!rows.showsClassifier)
        for field in [rows.harness, rows.model, rows.prompt] { #expect(!field.isDescendant(of: view), "closed again") }
    }

    @Test func theSetForwardsTheClassifierFields() {
        #expect(Set(["classifier_harness", "classifier_model", "classifier_prompt", "reactions_can_wake"]).isSubset(of: HomeChiefEngineSet.fieldKeys))
    }
}

/// A brain that resolved the classifier defaults; `own` is this Chief's own model (and then wake off).
private struct ReactingChief: HomeChiefEngineSource {
    let writes: AsyncStream<[String: String?]>.Continuation
    let own: String?
    var isLocal: Bool { true }
    var place: String? { nil }

    var snapshot: HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: "claude", model: nil, effort: nil, avatar: nil, turns: [])
        snapshot.effective = HomeChiefReactionRowsTests.resolved
        if let own {
            snapshot.classifierModel = own
            snapshot.reactionsCanWake = "false"
            snapshot.effective?.reactionsCanWake = false
        }
        return snapshot
    }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { snapshot }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        writes.yield(fields)
        return snapshot
    }
}
